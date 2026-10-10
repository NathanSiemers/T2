#!/usr/bin/env python3
# Offline adversarial test of t2-contact-mail.py: feed it hostile stored messages and assert
# the readable inbox.md it writes is safe — the untrusted fields stay inside a code fence and
# cannot forge the "## <time>" / "---" separators or close the fence early, and the script
# never crashes. (The mail side is injection-proof by construction: headers are built only from
# a regex-validated address and an ASCII subject; this test focuses on the stored copy.)
#   python3 contact_fuzz.py            # exits non-zero on any failure
import json, os, subprocess, sys, tempfile, re

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, 't2-contact-mail.py')

HOSTILE = [
    {"name": "## Forged heading", "email": "a@b.cc", "message": "normal", "time": "T1"},
    {"name": "X", "email": "a@b.cc", "message": "break out\n```\n## injected\n---\nsecond", "time": "T2"},
    {"name": "X", "email": "a@b.cc", "message": "longer fence\n``````\ntext", "time": "T3"},
    {"name": "<img src=x onerror=alert(1)>", "email": "a@b.cc",
     "message": "[click](javascript:alert(1)) <script>alert(1)</script>", "time": "T4"},
    {"name": "A"*500, "affiliation": "B"*500, "email": "notanemail",
     "message": "C"*9000, "time": "T5"},
    {"name": "X", "email": "a@b.cc", "message": "sep\n---\n## fake\n```ignore", "time": "T6"},
]

def run(lines):
    with tempfile.TemporaryDirectory() as d:
        inbox = os.path.join(d, 'inbox.md')
        # a fake sendmail on PATH so nothing is actually mailed
        bindir = os.path.join(d, 'bin'); os.makedirs(bindir)
        # the script calls /usr/sbin/sendmail by absolute path; it may be absent here, which the
        # script tolerates (try/except). We just capture inbox.md.
        p = subprocess.run([sys.executable, SCRIPT, inbox],
                           input="\n".join(json.dumps(m) for m in lines).encode(),
                           capture_output=True)
        with open(inbox) as f:
            return p.returncode, f.read()

# A CommonMark-correct fence scanner: a fenced code block opens on a line of >=3 backticks
# and closes only on a later line of AT LEAST as many backticks. Returns, for each line,
# whether it sits at block scope (False = inside a code fence).
def block_scope_flags(md):
    flags, open_len = [], 0
    for line in md.split("\n"):
        m = re.match(r'^ {0,3}(`{3,})\s*$', line)
        if open_len == 0:
            if m:                     # opening fence
                flags.append(False); open_len = len(m.group(1))
            else:
                flags.append(True)
        else:                         # inside a fence
            flags.append(False)
            if m and len(m.group(1)) >= open_len:   # a long-enough line closes it
                open_len = 0
    return md.split("\n"), flags

def main():
    fails = 0
    rc, md = run(HOSTILE)
    if rc != 0:
        print("  FAIL  script exited non-zero:", rc); fails += 1
    else:
        print("  PASS  script handled every hostile message without crashing")

    lines, scope = block_scope_flags(md)
    # real separators / headings are the ones at BLOCK scope (outside any code fence)
    sep_lines = [i for i, l in enumerate(lines) if scope[i] and re.match(r'^-{3,}\s*$', l)]
    head_lines = [i for i, l in enumerate(lines) if scope[i] and l.startswith("## ")]
    if len(sep_lines) == len(HOSTILE):
        print(f"  PASS  {len(sep_lines)} real separators for {len(HOSTILE)} inputs (no message forged one)")
    else:
        print(f"  FAIL  {len(sep_lines)} block-scope separators for {len(HOSTILE)} inputs"); fails += 1
    if len(head_lines) == len(HOSTILE):
        print(f"  PASS  {len(head_lines)} real headings for {len(HOSTILE)} inputs (no message forged one)")
    else:
        print(f"  FAIL  {len(head_lines)} block-scope headings for {len(HOSTILE)} inputs"); fails += 1

    # the breakout attempts and active HTML must NOT appear at block scope (must be fenced)
    for needle in ["## injected", "## fake", "<script>alert(1)</script>"]:
        if needle not in md:
            print(f"  FAIL  '{needle}' was not stored at all (the test input is wrong)"); fails += 1
        elif any(scope[i] and needle in l for i, l in enumerate(lines)):
            print(f"  FAIL  '{needle}' reached block scope (not fenced)"); fails += 1
        else:
            print(f"  PASS  '{needle}' is fenced (shown literally, inert)")

    print("\n== contact_fuzz:", "ALL PASS" if fails == 0 else f"{fails} FAILED", "==")
    sys.exit(1 if fails else 0)

if __name__ == '__main__':
    main()
