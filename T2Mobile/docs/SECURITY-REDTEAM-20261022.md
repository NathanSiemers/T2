# API red-team round, 2026-10-22 night (branch round-20261020)

Nathan (the API owner): "I want you to be imaginative about how to break the security of the api. Be thoughtful,
take your time, try to break it, and fix every weakness. ... I am the owner of this api and it is important to
test it. ... proceed autonomously in the development environment."

## Rules of engagement (hard boundaries)

- **Target: the local dev instance `t2api-sec` on `http://127.0.0.1:3871` ONLY** (its own Docker network
  `t2api-sec`, same image as the branch, dev data, read-only mounts). Also allowed: `t2api-hard` (3870),
  `t2api-dev` (3861) if a second target helps.
- **NEVER touch production**: no request to `www.fiveprime.org` or `99.132.144.201`, no `/scratch/shinyusb`,
  no `/scratch/Docker`, no `deploy.sh` mutating step (FREEZE is in force). No restart of a production container.
- Testing is DAST against software the owner controls, on localhost. No third-party systems are in scope.
- Findings are fixed on the branch `round-20261020` and verified against `t2api-sec`, then the full suite.
  Nothing is released (production freeze for the iOS review).

## Attack surface (the service is read-only SQLite behind Nginx; see API.md, DATASET-CONTRACT.md)

1. **Injection**: query params and path values (`{ds}`, probes, probe, fill, v, q, limit, all) into SQL,
   file paths, the hand-written JSON writer, headers, log lines. SQL injection, path traversal, response
   splitting, log injection, JSON breakout.
2. **Resource exhaustion / DoS**: huge/negative/overflow numbers, giant probe lists, pathological `q`,
   the contact POST body, slowloris, compression amplification (gzip), cache flooding, goroutine/memory growth.
3. **Trust boundary**: `X-Real-IP` / `X-Forwarded-For` spoofing (rate-limit and metrics bypass), the contact
   honeypot and limiter, reaching the service directly past Nginx.
4. **Memory safety / crashes**: inputs that panic a handler, NaN/Inf in the JSON, integer conversions,
   unicode edge cases, malformed query strings, oversized headers.
5. **Information disclosure**: internal paths or SQL in errors, version/metadata leakage, cache of
   sensitive answers, timing.
6. **Cache correctness**: key variants (repeated/reordered/unknown params), stale after version change.

## Method

Lead (imagination + triage): picks attack classes, reviews agent findings, verifies each, specs fixes.
Sonnet agents (engineers): run crafted requests against t2api-sec, record exact request + response + why it
is a weakness, propose a fix. No agent commits. The lead fixes, re-tests, commits, checkpoints.

## Findings (lead-verified; open / fixed <commit> / rejected)

(filled in as the round runs)

## Checkpoints (newest first)

### 2026-10-22 ~23:40 PDT: round opened
- t2api-sec up on 3871 (own network, dev data, read-only). Red-team agents launching: (1) injection + parsing,
  (2) DoS + resource exhaustion + compression, (3) trust boundary + cache + contact. Prior static review A
  found no critical/high and the Go hardening round (committed 01a1fee) already closed A1/A3/A4/A6-A9/A12 and
  the unknown/repeated/malformed-parameter cache route; this round is active fuzzing to find what reading missed.
