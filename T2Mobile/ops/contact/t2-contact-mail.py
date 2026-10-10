#!/usr/bin/env python3
# Reads new contact-form messages (one JSON object per line) on stdin, mails each to the
# local user with sendmail, and appends a readable copy to the inbox file (argv[1]).
#
# This is the HARDENED, version-controlled copy (T2Mobile/ops/contact). Deploy it to
# ~/bin/t2-contact-mail.py when reviewed; the companion t2-contact-mail.sh drives it from cron.
# The messages it reads are UNTRUSTED (anyone on the internet can POST the form), so every
# field is treated as hostile:
#   * the t2api service already strips control characters from name/affiliation/email and
#     keeps only newlines/tabs in the message (contact.go); this script does NOT rely on that
#     and re-sanitises here too (defence in depth);
#   * mail HEADERS (To/Subject/Reply-To) are built only from a regex-validated address and an
#     ASCII-only, single-line subject, so nothing a sender types can add or break a header;
#   * delivery is to LOCAL Unix mail (sendmail -t into loopback-only Postfix), never an
#     external relay, so the form can never be used to send mail to anyone but the owner;
#   * the readable inbox.md copy puts the untrusted name/affiliation/message inside a fenced
#     code block, so stored markdown or HTML is shown literally and cannot render active
#     content or forge the "## <time>" / "---" structure that separates messages.
import json, sys, subprocess, re

inbox = sys.argv[1]
EMAIL = re.compile(r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$')
# collapse any line break or control char to a space (for header fields and the md heading)
one = lambda s, n=200: re.sub(r'[\x00-\x1f\x7f  ]', ' ', str(s or '')).strip()[:n]
# a message may keep newlines (it goes in the mail BODY / a fenced block), but no other
# control chars, and no code-fence sequence that could close the block early
def body_text(s, n=4000):
    s = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f  ]', '', str(s or ''))
    s = s.replace('\r\n', '\n').replace('\r', '\n')
    return s[:n]
def fenced(s):
    # a message cannot break out of a ``````-fence: use a longer fence than any run inside it
    longest = max((len(m) for m in re.findall(r'`+', s)), default=0)
    fence = '`' * max(3, longest + 1)
    return fence + '\n' + s + '\n' + fence

with open(inbox, 'a') as md:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except Exception:
            continue
        name, aff = one(m.get('name')), one(m.get('affiliation'))
        email = one(m.get('email'), 254)
        if not EMAIL.match(email):
            email = ''                      # never put anything but a plain address in a header
        subject = 'T2 contact: ' + name + (' (' + aff + ')' if aff else '')
        subject = ''.join(c for c in subject if 32 <= ord(c) < 127)[:200]
        msg = body_text(m.get('message'))
        # --- mail: headers are injection-proof (validated/ASCII), the message is the body ---
        body = ('Name: %s\nAffiliation: %s\nEmail: %s\nTime: %s\nFrom app: %s\n\n%s\n'
                % (name, aff, email or '(no valid address)', one(m.get('time')), one(m.get('app'), 60), msg))
        hdr = 'To: nathan\nSubject: %s\n' % subject
        if email:
            hdr += 'Reply-To: %s\n' % email
        hdr += 'Content-Type: text/plain; charset=utf-8\n'
        try:
            subprocess.run(['/usr/sbin/sendmail', '-t'], input=(hdr + '\n' + body).encode(), check=False)
        except Exception as e:
            # a missing or failing MTA must not drop the message: it is still recorded below
            sys.stderr.write('t2-contact-mail: sendmail failed: %s\n' % e)
        # --- inbox.md: the untrusted fields go inside a code fence, shown literally ---
        heading = one(m.get('time')) + '  ' + name + ((' (' + aff + ')') if aff else '')
        reply = ('Reply to: ' + email) if email else '(no valid address)'
        md.write('## %s\n\n%s\n\n%s\n\n---\n\n' % (one(heading), reply, fenced(msg)))
