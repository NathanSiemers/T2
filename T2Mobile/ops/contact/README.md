# Contact-form mail delivery (host side)

The T2 contact form (iPhone app About screen, and the Shiny site's About tab) POSTs a message
to the t2api service, which appends it as one JSON line to `messages.jsonl` and writes nothing
else (no address, no log of successful requests). Delivery to the owner happens here, on the
host, so **no mail credential is ever near the container**:

- `t2-contact-mail.sh` — cron job (every 15 min). Tracks how many lines of `messages.jsonl` it
  has handled (`~/.t2-contact.state`) and pipes the new ones to the Python script.
- `t2-contact-mail.py` — for each new message: sends it to **local Unix mail** (`sendmail -t`
  into loopback-only Postfix, `default_transport = local`) and appends a readable copy to
  `inbox.md`.

These are the **version-controlled, hardened** copies. Deploy to `~/bin/` after review:

    install -m 755 t2-contact-mail.py t2-contact-mail.sh ~/bin/
    # cron (crontab -e), every 15 min:
    # */15 * * * * ~/bin/t2-contact-mail.sh >> ~/.t2-contact.log 2>&1

## Why the contact path is not a vulnerability

The stored messages are untrusted (anyone can POST the form), so they are treated as hostile
at every hop:

1. **The service** (`cmd/t2api/contact.go`): body size cap (16 KB), JSON only, unknown fields
   rejected; control characters stripped from name/affiliation/email (`oneLine`) and all but
   newline/tab stripped from the message (`paragraphs`); the address must match a strict
   pattern; a honeypot field and a 3-second minimum fill time drop simple bots; per-IP (5/day),
   global (200/day) and 20 MB-store caps bound flooding; Nginx adds 1 req/min per address and a
   32 KB body cap. The client address is used only for the in-memory rate limit — never stored
   or logged. Each message is one JSON-escaped line.
2. **This script** re-sanitises everything (does not trust the file): mail headers
   (To/Subject/Reply-To) are built only from a regex-validated address and an ASCII-only,
   single-line subject, so **no sender input can add or break a header**; the message is placed
   only in the mail body, past the header boundary. In `inbox.md` the untrusted
   name/affiliation/message go **inside a code fence** (longer than any backtick run inside
   them), so stored markdown or HTML is shown literally and cannot render active content or
   forge the `## <time>` / `---` separators between messages.
3. **Delivery is local-only.** `sendmail -t` hands the message to Postfix bound to loopback
   with `default_transport = local`; it is delivered to nathan's local mailbox and never
   relayed off the host. So even a (prevented) header injection could not send mail to anyone
   else — the form can never be a spam relay.

Verified 2026-10-10 against the dev service: a `name` of `Bad\r\nBcc: …` is stored as
`BadBcc: …` (CRLF stripped); a message with `\r\n` keeps only `\n` and stays in the body.
`service/fuzz.sh` section 5 and `test.sh abuse` exercise the endpoint; `contact_fuzz.py`
exercises this script offline.
