package main

// The contact form of the iPhone app ("Private deployments" in About). The owner's address
// never reaches a client: the app POSTs the message here, the server keeps it in an
// append-only file and, when an SMTP relay is configured, forwards it by mail.
//
// Defences: body size limit; every field length-limited, valid UTF-8, control characters
// removed (newlines allowed only in the message); nothing from the client is ever placed in
// a mail header except a validated address in Reply-To; a honeypot field and a minimum fill
// time catch simple bots (they are told "ok" and dropped); per-client and global rate limits
// in addition to Nginx's; the store stops accepting at a size cap. Responses are generic.

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/smtp"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

type contactConfig struct {
	dir      string // where messages are appended (one JSON object per line); "" = feature off
	to       string // recipient; never sent to clients
	from     string // envelope / From: address for the relay
	smtpHost string
	smtpPort string
	smtpUser string
	smtpPass string
}

func contactConfigFromEnv() contactConfig {
	return contactConfig{
		dir: os.Getenv("T2_CONTACT_DIR"), to: os.Getenv("T2_CONTACT_TO"), from: os.Getenv("T2_CONTACT_FROM"),
		smtpHost: os.Getenv("T2_SMTP_HOST"), smtpPort: os.Getenv("T2_SMTP_PORT"),
		smtpUser: os.Getenv("T2_SMTP_USER"), smtpPass: os.Getenv("T2_SMTP_PASSWORD"),
	}
}

const (
	contactMaxBody    = 16 << 10        // bytes of request body
	contactMaxField   = 200             // name, affiliation
	contactMaxEmail   = 254             //
	contactMaxMessage = 4000            // characters
	contactMinSeconds = 3               // a form filled in faster than this is a bot
	contactStoreCap   = 20 << 20        // bytes; beyond this the store refuses (someone is flooding)
	contactPerIP      = 5               // messages per client address per day
	contactPerDay     = 200             // messages per day in all
)

var emailPattern = regexp.MustCompile(`^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$`)

type contactLimiter struct {
	mu    sync.Mutex
	day   time.Time
	byIP  map[string]int
	total int
}

func (l *contactLimiter) allow(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.day) > 24*time.Hour {
		l.day, l.byIP, l.total = now, map[string]int{}, 0
	}
	if l.total >= contactPerDay || l.byIP[ip] >= contactPerIP {
		return false
	}
	l.total++
	l.byIP[ip]++
	return true
}

// oneLine keeps printable text on one line (a name, an affiliation): no control characters,
// so it can never break a mail header or a log line
func oneLine(s string, max int) string {
	s = strings.ToValidUTF8(strings.TrimSpace(s), "")
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
	if utf8.RuneCountInString(s) > max {
		r := []rune(s)
		s = string(r[:max])
	}
	return s
}

// paragraphs keeps text with newlines and tabs, nothing else from the control range
func paragraphs(s string, max int) string {
	s = strings.ToValidUTF8(strings.TrimSpace(s), "")
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
	if utf8.RuneCountInString(s) > max {
		r := []rune(s)
		s = string(r[:max])
	}
	return s
}

type contactMessage struct {
	Time        string `json:"time"`
	IP          string `json:"ip"`
	Name        string `json:"name"`
	Affiliation string `json:"affiliation"`
	Email       string `json:"email"`
	Message     string `json:"message"`
	App         string `json:"app,omitempty"`
	Mailed      bool   `json:"mailed"`
}

// clientIP: the address Nginx saw (X-Forwarded-For is set by our own proxy; the direct
// connection is the proxy itself)
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.Index(xff, ","); i >= 0 {
			xff = xff[:i]
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *server) handleContact(w http.ResponseWriter, r *http.Request) {
	cfg := s.contact
	if cfg.dir == "" {
		s.fail(w, http.StatusNotFound, "the contact form is not enabled on this server")
		return
	}
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		s.fail(w, http.StatusUnsupportedMediaType, "send JSON")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, contactMaxBody)
	var in struct {
		Name        string  `json:"name"`
		Affiliation string  `json:"affiliation"`
		Email       string  `json:"email"`
		Message     string  `json:"message"`
		Website     string  `json:"website"` // honeypot: a real person never sees this field
		Started     float64 `json:"started"` // seconds since the form appeared
		App         string  `json:"app"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		s.fail(w, http.StatusBadRequest, "bad request")
		return
	}
	ip := clientIP(r)
	ok := func() { // what every accepted-looking request gets, bots included
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, map[string]any{"ok": true})
	}
	if in.Website != "" || in.Started < contactMinSeconds {
		log.Printf("contact: dropped a bot-like submission from %s", ip)
		ok()
		return
	}
	m := contactMessage{
		Time: time.Now().UTC().Format(time.RFC3339), IP: ip,
		Name: oneLine(in.Name, contactMaxField), Affiliation: oneLine(in.Affiliation, contactMaxField),
		Email: oneLine(in.Email, contactMaxEmail), Message: paragraphs(in.Message, contactMaxMessage),
		App: oneLine(in.App, 60),
	}
	if m.Name == "" || m.Message == "" || !emailPattern.MatchString(m.Email) {
		s.fail(w, http.StatusBadRequest, "name, a valid email address and a message are needed")
		return
	}
	if !s.contactLimit.allow(ip, time.Now()) {
		s.fail(w, http.StatusTooManyRequests, "too many messages; please try again tomorrow")
		return
	}
	m.Mailed = mailContact(cfg, m)
	if err := storeContact(cfg.dir, m); err != nil {
		log.Printf("contact: could not store a message: %v", err)
		if !m.Mailed {
			s.fail(w, http.StatusServiceUnavailable, "the message could not be kept; please try again later")
			return
		}
	}
	log.Printf("contact: message from %s (%s), mailed=%v", m.Name, ip, m.Mailed)
	ok()
}

func storeContact(dir string, m contactMessage) error {
	path := filepath.Join(dir, "messages.jsonl")
	if fi, err := os.Stat(path); err == nil && fi.Size() > contactStoreCap {
		return fmt.Errorf("store is full (%d bytes)", fi.Size())
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o640) // owner = the service user, group = the host group that may read the messages
	if err != nil {
		return err
	}
	defer f.Close()
	b, _ := json.Marshal(m) // Marshal escapes everything; one line per message
	_, err = f.Write(append(b, '\n'))
	return err
}

// mailContact forwards the message through the configured relay (STARTTLS + auth). Every
// header value is our own text or a validated address; the client's text is only in the body.
func mailContact(cfg contactConfig, m contactMessage) bool {
	if cfg.smtpHost == "" || cfg.to == "" || cfg.from == "" {
		return false
	}
	port := cfg.smtpPort
	if port == "" {
		port = "587"
	}
	subject := "T2 contact form: " + m.Name
	if m.Affiliation != "" {
		subject += " (" + m.Affiliation + ")"
	}
	body := fmt.Sprintf("Name: %s\r\nAffiliation: %s\r\nEmail: %s\r\nTime: %s\r\nFrom app: %s\r\nClient address: %s\r\n\r\n%s\r\n",
		m.Name, m.Affiliation, m.Email, m.Time, m.App, m.IP, strings.ReplaceAll(m.Message, "\n", "\r\n"))
	msg := "From: T2 contact form <" + cfg.from + ">\r\n" +
		"To: " + cfg.to + "\r\n" +
		"Reply-To: " + m.Email + "\r\n" + // validated by emailPattern: no spaces, no CR/LF
		"Subject: " + mimeSafe(subject) + "\r\n" +
		"MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + body
	addr := net.JoinHostPort(cfg.smtpHost, port)
	done := make(chan error, 1)
	go func() {
		c, err := smtp.Dial(addr)
		if err != nil {
			done <- err
			return
		}
		defer c.Close()
		if err := c.StartTLS(&tls.Config{ServerName: cfg.smtpHost}); err != nil {
			done <- err
			return
		}
		if cfg.smtpUser != "" {
			if err := c.Auth(smtp.PlainAuth("", cfg.smtpUser, cfg.smtpPass, cfg.smtpHost)); err != nil {
				done <- err
				return
			}
		}
		if err := c.Mail(cfg.from); err != nil {
			done <- err
			return
		}
		if err := c.Rcpt(cfg.to); err != nil {
			done <- err
			return
		}
		wc, err := c.Data()
		if err != nil {
			done <- err
			return
		}
		if _, err := wc.Write([]byte(msg)); err != nil {
			done <- err
			return
		}
		if err := wc.Close(); err != nil {
			done <- err
			return
		}
		done <- c.Quit()
	}()
	select {
	case err := <-done:
		if err != nil {
			log.Printf("contact: mail not sent: %v", err)
			return false
		}
		return true
	case <-time.After(15 * time.Second):
		log.Printf("contact: mail not sent: timeout talking to %s", addr)
		return false
	}
}

// mimeSafe keeps a subject to plain ASCII on one line (non-ASCII is dropped; the body holds the original)
func mimeSafe(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r > 126 {
			return -1
		}
		return r
	}, s)
}
