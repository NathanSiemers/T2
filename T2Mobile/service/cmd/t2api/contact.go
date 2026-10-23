package main

// The contact form of the iPhone app ("Private deployments" in About). The owner's address
// never reaches a client: the app POSTs the message here and the server keeps it in an
// append-only file (one JSON object per line). Delivery to the owner happens outside this
// service: a cron job on the host reads the file and mails new messages to the local user
// (~/bin/t2-contact-mail.sh), so no mail credential exists anywhere.
//
// Defences: body size limit; every field length-limited, valid UTF-8, control characters
// removed (newlines allowed only in the message); the address must match a strict pattern;
// a honeypot field and a minimum fill time catch simple bots (they are told "ok" and
// dropped); per-client and global rate limits in addition to Nginx's; the store stops
// accepting at a size cap. Responses are generic.

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"net/mail"
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
	dir string // where messages are appended (one JSON object per line); "" = feature off
}

func contactConfigFromEnv() contactConfig {
	return contactConfig{dir: os.Getenv("T2_CONTACT_DIR")}
}

const (
	contactMaxBody    = 16 << 10 // bytes of request body
	contactMaxField   = 200      // name, affiliation
	contactMaxEmail   = 254      //
	contactMaxMessage = 4000     // characters
	contactMinSeconds = 3        // a form filled in faster than this is a bot
	contactStoreCap   = 20 << 20 // bytes; beyond this the store refuses (someone is flooding)
	contactPerIP      = 5        // messages per client address per day
	contactPerDay     = 200      // messages per day in all
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

// allowIP counts against the per-address budget only: bot-like submissions must not use up the
// shared daily quota (a flood of honeypot posts would lock real visitors out for the day)
func (l *contactLimiter) allowIP(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.day) > 24*time.Hour {
		l.day, l.byIP, l.total = now, map[string]int{}, 0
	}
	if l.byIP[ip] >= contactPerIP {
		return false
	}
	l.byIP[ip]++
	return true
}

// oneLine keeps printable text on one line (a name, an affiliation): no control characters,
// so it can never break a mail header or a log line
func oneLine(s string, max int) string {
	s = strings.ToValidUTF8(strings.TrimSpace(s), "")
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Zl, r) || unicode.Is(unicode.Zp, r) ||
			(r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) { // line/paragraph separators, bidi controls
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

// contactMessage is what is kept: what the sender typed, and when. The client address is
// used for the rate limit only (in memory) and is neither stored nor logged (2026-10-07:
// the app's privacy policy promises exactly that).
type contactMessage struct {
	Time        string `json:"time"`
	Name        string `json:"name"`
	Affiliation string `json:"affiliation"`
	Email       string `json:"email"`
	Message     string `json:"message"`
	App         string `json:"app,omitempty"`
}

// trustedProxies: networks whose X-Real-IP / X-Forwarded-For are believed (-trusted-proxies).
// Empty by default: then the TCP peer is always the client.
var trustedProxies []*net.IPNet

func parseTrustedProxies(list string) ([]*net.IPNet, error) {
	var out []*net.IPNet
	for _, p := range strings.Split(list, ",") {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		_, n, err := net.ParseCIDR(p)
		if err != nil {
			return nil, fmt.Errorf("bad CIDR %q", p)
		}
		out = append(out, n)
	}
	return out, nil
}

// validClientIP: a header value is used only if it is a plain IP address (no port, no text).
func validClientIP(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if s == "" || len(s) > 45 || net.ParseIP(s) == nil {
		return "", false
	}
	return s, true
}

// clientIP: the visitor's address. The trust model: the TCP peer (r.RemoteAddr) cannot be
// forged, the headers can. Only when the peer is inside -trusted-proxies (our Nginx) are its
// headers believed: X-Real-IP is set by replacement there (a visitor cannot forge it);
// X-Forwarded-For is appended to, so only its LAST entry is the proxy's word (the first
// entries are whatever the client sent). A value that is not a plain IP of at most 45
// characters is ignored. With no trusted proxy (the default, and the dev/direct case) the
// answer is always the peer's address, so a client that reaches the service past Nginx cannot
// pick the address the per-address limit counts. Used by the contact limiter and by usage.go.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if len(trustedProxies) > 0 {
		if peer := net.ParseIP(host); peer != nil {
			for _, n := range trustedProxies {
				if !n.Contains(peer) {
					continue
				}
				if ip, ok := validClientIP(r.Header.Get("X-Real-IP")); ok {
					return ip
				}
				if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
					if i := strings.LastIndex(xff, ","); i >= 0 {
						xff = xff[i+1:]
					}
					if ip, ok := validClientIP(xff); ok {
						return ip
					}
				}
				break
			}
		}
	}
	return host
}

// validEmail: net/mail must parse a bare address (no display name), and the domain may not
// hold empty labels ("a@b..cc"); the strict pattern still applies on top.
func validEmail(s string) bool {
	a, err := mail.ParseAddress(s)
	if err != nil || a.Address != s || a.Name != "" {
		return false
	}
	at := strings.LastIndex(s, "@")
	return at > 0 && !strings.Contains(s[at+1:], "..") && emailPattern.MatchString(s)
}

func (s *server) handleContact(w http.ResponseWriter, r *http.Request) {
	cfg := s.contact
	if cfg.dir == "" {
		s.fail(w, http.StatusNotFound, "the contact form is not enabled on this server")
		return
	}
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
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
	if _, err := dec.Token(); err != io.EOF { // trailing data after the object
		s.fail(w, http.StatusBadRequest, "bad request")
		return
	}
	ip := clientIP(r)
	ok := func() { // what every accepted-looking request gets, bots included
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, map[string]any{"ok": true})
	}
	// bot-like submissions: the per-address budget bounds the log lines a client can write; over
	// it they get the same silent ok (no 429: a bot learns nothing) and never touch the shared quota
	bot := in.Website != "" || in.Started < contactMinSeconds
	if bot {
		if s.contactLimit.allowIP(ip, time.Now()) {
			log.Printf("contact: dropped a bot-like submission")
		}
		ok()
		return
	}
	m := contactMessage{
		Time: time.Now().UTC().Format(time.RFC3339),
		Name: oneLine(in.Name, contactMaxField), Affiliation: oneLine(in.Affiliation, contactMaxField),
		Email: oneLine(in.Email, contactMaxEmail), Message: paragraphs(in.Message, contactMaxMessage),
		App: oneLine(in.App, 60),
	}
	if m.Name == "" || m.Message == "" || !validEmail(m.Email) {
		s.fail(w, http.StatusBadRequest, "name, a valid email address and a message are needed")
		return
	}
	if !s.contactLimit.allow(ip, time.Now()) {
		s.fail(w, http.StatusTooManyRequests, "too many messages; please try again tomorrow")
		return
	}
	if err := storeContact(cfg.dir, m); err != nil {
		log.Printf("contact: could not store a message: %v", err)
		s.fail(w, http.StatusServiceUnavailable, "the message could not be kept; please try again later")
		return
	}
	log.Printf("contact: a message was stored")
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
