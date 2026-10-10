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
	"log"
	"net"
	"net/http"
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

// clientIP: the visitor's address as our own proxy states it. The service is reachable
// only through Nginx (or, on the Docker network, the Shiny app), so these headers are ours:
// X-Real-IP is set by replacement (a visitor cannot forge it); X-Forwarded-For is appended
// to, so only its LAST entry is the proxy's word — the first entries are whatever the
// client sent, and taking the first would let a visitor pick the address the per-address
// limit counts.
func clientIP(r *http.Request) string {
	if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); real != "" {
		return real
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.LastIndex(xff, ","); i >= 0 {
			xff = xff[i+1:]
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
		log.Printf("contact: dropped a bot-like submission")
		ok()
		return
	}
	m := contactMessage{
		Time: time.Now().UTC().Format(time.RFC3339),
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
