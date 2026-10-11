#!/usr/bin/env python3
# Adds the permission rule that lets Claude Code run ops/deploy.sh (by its full path, nothing
# else) to Nathan's user settings. Claude cannot edit its own permissions, so Nathan runs:
#     python3 /scratch/nathan/R/T2/T2Mobile/ops/allow-deploy.py
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) else {}
allow = d.setdefault("permissions", {}).setdefault("allow", [])
rule = "Bash(/scratch/nathan/R/T2/T2Mobile/ops/deploy.sh:*)"
if rule not in allow:
    allow.append(rule)
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print("allowed:", rule)
print("all allow rules:", allow)
