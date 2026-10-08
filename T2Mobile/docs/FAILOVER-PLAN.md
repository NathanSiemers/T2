# API standby: recommendation and plan (to decide soon)

Written 2026-10-07 by Claude after the scouting report in `FAILOVER.md` (prices there are
tagged by how well they were verified; several are from memory — check before buying).

## The problem

Everything at the house (nginx, the Shiny sites, `t2api`) sits behind one home IP
(99.132.144.201). A power cut takes the iPhone app's data service down with it. The app has
`https://www.fiveprime.org/api/t2` built in, so the fix has to keep that hostname and path.

Relevant facts: the `t2api` image is 15 MB; the data are three read-only SQLite files,
≈67 GB today (≈60 GB after the next TCGA rebuild); the service uses 75 MB RAM and no CPU to
speak of; fiveprime.org's DNS is already at Cloudflare (A record TTL 300 s, not proxied).

## Recommendation

**A warm standby at Hetzner, ≈ €8.5/month, switched by a watchdog — no human in the loop.**

| | |
|---|---|
| Machine | Hetzner Cloud CX33 (4 vCPU, 8 GB, 80 GB NVMe) ≈ €8.5/mo, or CX23 (€5.49) + 40 GB volume (≈ €2.4) — US locations exist (Ashburn, Hillsboro) |
| Runs | `t2api` (same image, same read-only volumes) + nginx with a Let's Encrypt certificate for `www.fiveprime.org`, obtained by DNS-01 through the Cloudflare API (works while the record still points home; renews itself) |
| Switch | a watchdog on the standby polls `https://99.132.144.201/api/t2/healthz` (and `/T2T/`) every 30 s; after 3 failures it sets the Cloudflare A record for `www` to the standby's IP; when home answers again for a few minutes, it sets it back |
| Gap | 3–7 minutes (detection + 300 s TTL + resolver caching); nobody has to act |
| During a flip | the standby serves `/api/t2/…` normally and a short "fiveprime.org is temporarily down" page for every other path (the Shiny sites share `www`) |
| Data refresh | after each database rebuild, `rsync` the new files up (a few times a year), then `docker compose up -d` there — same "new directory + volume change" rule as at home |
| Second copy | the data files in Cloudflare R2 (≈ $1/mo, free egress): a backup of the backup, not the failover path (pulling 70 GB onto a fresh VM takes 15–45 min) |

Why warm, not cold: a stopped VM costs only its disk at AWS/GCP (≈ $6–7/mo) but then
something alive must start it (Cloudflare health check → webhook → Worker → vendor API →
boot → DNS flip): more parts for ≈ $2/month saved. At Hetzner/DO/Vultr/Linode a stopped VM
is billed in full anyway.

Why not Oracle's free ARM tier ($0): it would run this (the Go service builds for arm64), but
Oracle reclaims idle free instances — our idle API is exactly that pattern — and creation
often fails for lack of capacity. Fine as an experiment, not the thing to rely on.

## Upgrade if the gap matters

Cloudflare Load Balancing (from $5/mo) with health checks fails over in seconds, but the
`www` record must then be proxied (orange cloud), which puts the Shiny sites behind
Cloudflare too (edge TLS; the GoDaddy or an Origin CA certificate stays on the origin; Shiny's
websockets work through Cloudflare). Worth it only if 3–7 minutes of outage per power cut is
not acceptable.

## Decisions for Nathan

1. Is a 3–7 minute gap acceptable (watchdog + DNS), or do we want Cloudflare LB (+$5/mo,
   `www` proxied)?
2. Hetzner OK (EU company; US data centres available)? Alternatives at the same shape cost
   ≈ $18–24/mo.
3. Go ahead? Nathan creates the Hetzner account and a Cloudflare API token (Zone:DNS:Edit
   for fiveprime.org only); Claude does the rest.

## Steps once decided (≈ half a day)

1. Hetzner: create the server (Ubuntu LTS, US location), firewall 22/80/443, Docker.
2. Copy the data (`rsync` the served directory, ≈ 67 GB — hours at home upload speed; or
   from R2 if the copy is there), the image (`docker save | ssh … docker load`, or build
   from the repo), and a compose file with the same read-only volumes.
3. nginx on the standby: the same `/api/t2/` locations (rate limits, failed-requests-only
   log), the "temporarily down" page for the rest; certificate via `certbot` /
   `lego` with the Cloudflare DNS-01 plugin.
4. The watchdog (a 60-line script, systemd timer): health checks, hysteresis, Cloudflare
   DNS API, a line in a log and an email to Nathan on every flip.
5. Test: take the home API down deliberately (stop the container) → watch the flip → start
   it → watch the flip back; measure the gap from the phone.
6. Document in `docs/API.md` (operators) and `NOTES.md`; add the standby to the database
   deployment checklist.
