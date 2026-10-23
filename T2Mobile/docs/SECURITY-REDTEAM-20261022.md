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

## Findings (lead-verified)

### Injection + parsing agent (t2api-sec): NO SQLi, traversal, JSON breakout, header/log injection, or panic.
Every untrusted value is bound or used only as a map key; the {ds} segment is a map key, never a path; the JSON
writer escapes quotes/backslashes/control/`</script>`/invalid-UTF-8/U+2028-9; CR/LF/NUL in names 400; 100-probe cap
holds; contact body cap, DisallowUnknownFields, 10k nesting all hold. ~190 requests.
- R1 (medium, OPEN): cache-key multiplication by VALUE variants of valid params. `all` accepts any value (all=2,
  all=x behave as all=1), `limit` junk falls back to 50, `fill=NA` is lowercased, probe lists differ by order /
  padding / empty parts; each distinct URL is immutable-cacheable, so one answer has unlimited cacheable URLs.
  Fix (service): accept `all` only =1, `limit` only a positive int else 400, `fill` exact na|zero|floor, reject
  probe lists with empty/whitespace parts; emit immutable only for a canonical request. -> Go round 3.
- R2 (low, OPEN): no X-Content-Type-Options: nosniff on JSON. -> Go round 3.
- R3 (low, OPEN): contact parsing laxness: `application/jsonx` accepted (use mime.ParseMediaType exact), trailing
  JSON after the object ignored (require dec.More()==false), weak email regex (net/mail.ParseAddress). -> Go round 3.

### Trust + cache + contact agent (t2api-sec): CONFIRMED the X-Real-IP/X-Forwarded-For trust issue; everything
else hardened.
- R4 (medium, OPEN): clientIP/clientAddr trust X-Real-IP / last X-Forwarded-For UNCONDITIONALLY. Proof: rotating
  X-Real-IP bypasses the contact 5/IP/day limit (8 varied IPs = 8 accepted) and skews /statz distinct_clients;
  a ~9 KB header value is accepted and keyed into the per-minute map (up to ~800 MB at the 50k cap). Only
  exploitable by a client that reaches the service past Nginx (review-D flat-network co-tenant). Fix (service):
  a -trusted-proxies CIDR gate; trust the headers only when RemoteAddr is a trusted proxy, else RemoteAddr;
  default trust none; validate with net.ParseIP and a length cap. Ship with the compose flag (staged, after
  freeze). -> Go round 3 + ops/pending/.
- Contact mail-injection HARDENED: CRLF / U+2028-9 / bidi / C1 stripped by oneLine/paragraphs; stored records
  verified in the dev store; email with a newline rejected; the downstream mailer re-sanitizes (defence in depth).
- Cache games HARDENED server-side: repeated param 400, encoding variants collide to one ETag, forged
  If-None-Match cannot cross-content 304 (ETag = sha256(version:key)), HEAD==GET, error/no-store never cached.
- Info disclosure: unknown dataset vs missing probe clean; no path/SQL/Go-type in errors; no pprof/metrics/vars;
  /statz is unauthenticated and verbose (no PII) -> low, gate behind the trust fix / internal bind in production.

## Checkpoints (newest first)

### 2026-10-22 ~00:40 (23rd) PDT: three agents reported; Shiny-specific red-team launching; DoS agent still out
- Both agents converge on the same two real, medium issues (cache-value multiplication; X-Real-IP trust) and
  confirm the injection/JSON/traversal/mail-injection surface is clean. These go into Go round 3 after the DoS
  agent reports, so one agent owns the service files.
- Nathan asked to test R/Shiny-specific weaknesses (hostile websocket client, shared-worker crash, XSS, download
  handler, server-side eval). Launching that agent against a Shiny instance pointed at t2api-sec. Reviews B and C
  committed (5e3f684, c28d0df); iOS round has 1 UI test (test05) failing, under triage.
### 2026-10-22 ~23:40 PDT: round opened
- t2api-sec up on 3871 (own network, dev data, read-only). Red-team agents launching: (1) injection + parsing,
  (2) DoS + resource exhaustion + compression, (3) trust boundary + cache + contact. Prior static review A
  found no critical/high and the Go hardening round (committed 01a1fee) already closed A1/A3/A4/A6-A9/A12 and
  the unknown/repeated/malformed-parameter cache route; this round is active fuzzing to find what reading missed.
