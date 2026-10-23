#!/usr/bin/env python3
# Adds permission rules that let Claude Code run the READ-ONLY steps of ops/deploy.sh
# (`status` and `check`, by full path, nothing else) in Nathan's user settings. Every mutating
# step (service, data, code, nginx, ...) stays a manual approval. Claude cannot edit its own
# permissions, so Nathan runs:
#     python3 /scratch/nathan/R/T2/T2Mobile/ops/allow-deploy.py
# An older broad rule "Bash(.../deploy.sh:*)" is NOT removed: delete it by hand if present.
import json, os, tempfile
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) else {}
allow = d.setdefault("permissions", {}).setdefault("allow", [])
script = "/scratch/nathan/R/T2/T2Mobile/ops/deploy.sh"
rules = ["Bash(%s status:*)" % script, "Bash(%s check:*)" % script]
for rule in rules:
    if rule not in allow:
        allow.append(rule)
# atomic write: temp file in the same directory, then rename over the settings file
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p) or ".", prefix=".settings.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    if os.path.exists(p):
        os.chmod(tmp, os.stat(p).st_mode & 0o777)
    os.replace(tmp, p)
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
print("allowed:", *rules, sep="\n  ")
broad = "Bash(%s:*)" % script
if broad in allow:
    print("NOTE: the broad rule is still present; remove it from", p, ":", broad)
