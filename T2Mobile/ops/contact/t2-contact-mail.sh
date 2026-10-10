#!/bin/bash
# New messages from the T2 contact form -> local Unix mail to nathan + a readable inbox.md.
# The t2api service appends one JSON object per line to messages.jsonl; this remembers how many
# lines it has handled and pipes the new ones to t2-contact-mail.py. Run by cron every 15 min;
# safe to run by hand any time.
#
# Version-controlled copy (T2Mobile/ops/contact); deploy to ~/bin when reviewed. See the .py
# header for the hardening. All paths are fixed; no message content ever reaches the shell.
# Each stored message is exactly one physical line (the service JSON-escapes newlines), so the
# line-count state and `tail -n +N` are safe even for a message that contained newlines.
set -euo pipefail
FILE=${T2_CONTACT_FILE:-/scratch/shinyusb/t2-contact/messages.jsonl}
INBOX=${T2_CONTACT_INBOX:-/scratch/shinyusb/t2-contact/inbox.md}
STATE=${T2_CONTACT_STATE:-$HOME/.t2-contact.state}
[ -r "$FILE" ] || exit 0
done_lines=$(cat "$STATE" 2>/dev/null || echo 0)
total=$(wc -l < "$FILE")
[ "$total" -gt "$done_lines" ] || exit 0
tail -n +"$((done_lines + 1))" "$FILE" | "$(dirname "$0")/t2-contact-mail.py" "$INBOX"
echo "$total" > "$STATE"
