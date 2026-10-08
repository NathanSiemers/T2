# API standby / failover — scouting report (Sonnet agent, 2026-10-07)

Research notes for Nathan's question: how to host a standby of `t2api` outside the house and switch the app's traffic to it when the house loses power. Prices are tagged V (read on the vendor's page), 3P (third-party snippet) or M (model memory) — check V/3P before deciding; M figures are indicative only. Claude's own recommendation is in NOTES.md (log entry 2026-10-07 night, 'Failover').

# Standby for the T2 API (www.fiveprime.org/api/t2) - options and prices

Prices read 2026-10-07. "V" = read from the vendor's own page via fetch; "3P" = only seen in a third-party article/search snippet; "M" = my recollection, not verified today. Several vendor pricing pages (Vultr, Oracle /cloud/free, GCP, Azure, Cloudflare LB page, Hetzner server tables) returned 403/404 or truncated content to my fetch tool, so those are flagged. Re-check before buying.

## Recommendation

**Primary: Oracle Cloud Always Free ARM VM kept running as a warm standby ($0), with a Cloudflare-API watchdog on that VM that flips the `www` A record when home fails health checks.** It costs nothing, needs no human, and 200 GB of free block storage holds the 70 GB. Caveat: Oracle may reclaim "idle" Always Free instances, and ARM capacity can be unavailable at creation time; see risks below. If Oracle is unusable or reclaims it, fall back to the runner-up.

**Runner-up: Hetzner Cloud, snapshot-only when idle** (server deleted, snapshot kept, about $1 per month; recreate in minutes from phone/API), plus a manual (phone) Cloudflare DNS flip. Running cost about EUR 5.5-8.5 per month while on. Humans must act, but cost is near zero.

Important side point: because `www` is also the Shiny site, a DNS flip moves the websites too. The standby would serve only /api/t2, so the DNS-flip approach needs the standby nginx to also return a "site is on backup" page for other paths (or use a Cloudflare Load Balancer / Worker with path rules). Cloudflare proxy mode (orange cloud) allows path-based routing by a Worker or Origin Rule; see 1c.

## 1. Redirection mechanism

| | Mechanism | Cost | Failover time | Who acts |
|---|---|---|---|---|
| a | Manual DNS edit at Cloudflare (app/API from phone) | $0 | TTL 300 s + resolver caching (some resolvers/iOS stretch or ignore low TTLs; assume 5-15 min) | Nathan, needs internet on his phone (cell data works in a power cut) |
| b1 | Cloudflare Load Balancing | "starts at $5/month" [V: https://www.cloudflare.com/plans/application-services/]; 3P: $5/mo for 2 origins + 5 health checks, +$5 per extra origin (https://costbench.com/software/load-balancers/cloudflare-load-balancing/). I could not retrieve the official origin/check/DNS-query table; verify at https://developers.cloudflare.com/load-balancing/ | DNS-only LB: still bounded by the LB record TTL (can be set low, ~60 s); proxied LB: seconds | Nobody |
| b2 | Watchdog on standby VM calls Cloudflare API to edit the A record (GET /zones/:id/dns_records, PATCH) | $0 | detection (e.g. 3 failed checks at 20 s) + TTL 300 s + caching | Nobody (but the watchdog is your own code; it needs a scoped API token, "DNS:Edit" on one zone) |
| c | Orange cloud proxy (+ optional Tunnel) | Proxy is on the Free plan (price not re-verified) | Seconds, because clients keep hitting Cloudflare IPs; origin swap is invisible | Nobody if combined with LB or a watchdog that edits the origin |
| d | Anycast / floating IP across providers | n/a | n/a | n/a |

**1a. Manual DNS.** Works, but only as fast as the 300 s TTL plus whatever caching resolvers do. Fine for an hours-long power cut, poor for a 20-minute one. Nathan on his phone can edit via the Cloudflare mobile app or one curl call. The failback is a second edit.

**1b. Automated.** The watchdog variant is the cheapest and close to the LB in effect when the home origin is DNS-only: both rely on a low-TTL record. Important: the watchdog must run OUTSIDE the house (it does, on the standby). Add hysteresis (flip only after N consecutive failures; flip back only after M successes) and have the watchdog check a real URL (`/api/t2/...` returning JSON), not just TCP. If the standby is a stopped VM, the watchdog cannot run on it; use a free external trigger instead (a Cloudflare Worker with a Cron Trigger doing the health check, start of the VM via provider API, then the DNS edit). That keeps the standby fully off. I have not priced Workers today (free tier existed: M).

**1c. Proxied mode.** Orange cloud: clients see Cloudflare's edge certificate (automatically issued, free), so the GoDaddy cert is no longer what iOS sees. Between Cloudflare and the origin you can keep the existing GoDaddy cert with SSL mode "Full (strict)" (requires a publicly trusted cert matching the hostname, which GoDaddy's is) or use a free Cloudflare Origin CA cert on the standby. Standby then does not need Let's Encrypt and its IP can change freely (update origin via API). A standard iOS app (URLSession, no pinning) has no issue; if the app pinned the old certificate, it would break, but the brief says nothing is pinned. Side effects: it applies to the Shiny sites too (websockets are supported by Cloudflare, but long-lived sessions, 100 MB upload limits on Free and any caching rules deserve a test), and the home IP is no longer exposed. Cloudflare Tunnel (`cloudflared`) would let the standby have no public inbound ports and no certificate work; the tunnel hostname is routed by Cloudflare; this requires proxied (orange) DNS. Cloudflare will route to the standby within seconds only if a Load Balancer (b1) or an automated origin switch is in place; the proxy alone does not fail over.

**1d. Better than DNS?** No. Anycast/BGP or a floating IP needs your own ASN and address space announced from several sites; a home connection with one dynamic/static residential IP cannot announce or share an address with a cloud provider, and a provider's floating IP is bound to that provider's network. The only equivalent is to put an anycast front door in front (Cloudflare proxy, i.e. 1c), which is what makes failover seconds instead of minutes.

## 2. Standby hosting (2 vCPU / 4 GB, 70-100 GB SSD)

| Vendor | Running $/mo | Stopped $/mo | Egress | Sources / notes |
|---|---|---|---|---|
| **Oracle Always Free** (A1 ARM) | $0 | $0 | 10 TB/mo free | [V] https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm : A1 Flex 1,500 OCPU-h + 9,000 GB-h per month ("equivalent to 2 OCPU and 12 GB" on that page; Oracle marketing often says 4 OCPU/24 GB, 3,000/18,000: the page I read says 2/12, so assume 2/12), 200 GB block storage total (boot + block), 10 TB egress. Idle reclamation: instance may be reclaimed if over 7 days 95th-percentile CPU <20%, network <20%, and (A1) memory <20%. This standby WILL meet those criteria. Mitigations: upgrade the account to Pay-As-You-Go (I believe PAYG accounts are exempt, not verified today), or run a small periodic busy-loop, or accept the risk. Creation can fail with "out of host capacity". |
| **Hetzner Cloud** | CX23 (2 vCPU/4 GB/40 GB) EUR 5.49 [V https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/]; CX33 (4 vCPU/8 GB/80 GB) EUR 8.49 [3P, https://northflank.com/blog/hetzner-cloud-server-price-increases]; CPX22 EUR 19.49 [V]; US: CPX11 $20.49, CCX13 $50.99 [V] (all excl. VAT, since the June 15 2026 increase) | **Stopped server billed in full** [V https://docs.hetzner.com/cloud/billing/faq/]. Delete server and keep a snapshot instead: snapshot price/GB [3P: about $0.01/GB, https://docs.hetzner.com/ not confirmed; billed on compressed size per V] = roughly $0.5-0.8 for 70 GB. Volumes: [3P] $0.06/GB/mo (=$4.2 for 70 GB); volumes have no snapshots/backups [V https://docs.hetzner.com/cloud/volumes/overview/]. | EU: 20 TB included (M); overage billed in 100 MB blocks [V]. Not re-verified US. | Use CX33 (80 GB root) so the DB lives on the root disk and a single snapshot restores everything. Time to recreate from snapshot: minutes (I did not measure; likely under 10 min for 80 GB). |
| DigitalOcean | 2 vCPU/2 GB/60 GB $18; 1 vCPU/2 GB/50 GB $12 [V https://www.digitalocean.com/pricing/droplets]. 2 vCPU/4 GB/80 GB $24 (M, unverified) | Powered-off droplets are billed in full (M; page said nothing); snapshots $0.06/GB/mo [V] => $4.2 (70 GB; snapshot size is used data) | Transfer pool included (3,000 GiB on the $18 plan) [V]; inbound free [V] | Stop+snapshot+destroy recreates in minutes. |
| Vultr | Regular 2 vCPU/4 GB/80 GB $20; High Perf AMD 2/4/100 NVMe $24 [3P: https://www.vultr.com/pricing/ snippet, page returned 403 to me] | Stopped instances still billed [V https://docs.vultr.com/support/platform/billing/are-stopped-instances-still-billed-on-vultr]; snapshot $0.05/GB [3P] => $3.5; NVMe block $0.10/GB [3P] | Included bandwidth (amount not verified) | |
| Linode/Akamai | Shared 4 GB: 2 vCPU/80 GB/4 TB, $24 [3P: bestusavps.com; akamai.com/cloud/pricing is a gateway page without numbers] | Powered-off billed (M); block storage $0.10/GB [3P] | 4 TB included | |
| AWS Lightsail | 2 vCPU/4 GB/80 GB/4 TB $24 [V https://aws.amazon.com/lightsail/pricing/] | The page said base instance fee stops when stopped; that contradicts my recollection (Lightsail bills stopped instances); UNVERIFIED, check. Snapshots $0.05/GB [V] => $3.5 | 4 TB included | |
| AWS EC2 + EBS | t4g.medium (2 vCPU/4 GB) about $24.5 (M, us-east-1 on-demand; not verified); t3.small (2 GB) about $15 (M) | Stopped: EBS only. gp3 $0.08/GB-mo (the EBS pricing page cites $0.08 only as an example) => $5.6 for 70 GB, $8 for 100 GB; snapshots $0.05/GB-mo [V https://aws.amazon.com/ebs/pricing/] | $0.09/GB after 100 GB free (M) => pennies | gp3 default 3,000 IOPS, enough. Start from phone via AWS app/CLI: about 1-2 min. |
| Google Cloud | e2-small about $12-15, e2-medium about $25 (M, page truncated for me) | Stopped: disk only. pd-balanced about $0.10/GB-mo (M) => $7-10; snapshots about $0.05/GB (M) | about $0.12/GB after free tier (M) | Page https://cloud.google.com/compute/disks-image-pricing gave no numbers to my fetch. |
| Azure B-series | Not researched (B2s about $30; M) | Stopped (deallocated): disk only, Premium SSD 128 GB about $18-20 (M) | | Unverified; not recommended on price. |
| Fly.io | shared-cpu-2x 4 GB $13.39/mo if always running (Ashburn) [V https://docs.fly.io/about/pricing] | Stopped machine pays only rootfs; volumes $0.15/GB-mo, first 10 GB free [V] => 70 GB about $9.00 (60 billable GB) | $0.02/GB NA/EU [V] | Volume snapshots $0.08/GB [V]. Pricey for idle, but starts in seconds. Needs a Fly volume attached to one machine only. |
| Object storage | R2 Standard $0.015/GB-mo, free egress, 10 GB free [V https://developers.cloudflare.com/r2/pricing/] => 70 GB about $1.05/mo (class A ops negligible). Backblaze B2 $6.95/TB-mo, egress free up to 3x stored, then $0.01/GB [V https://www.backblaze.com/cloud-storage/pricing] => $0.49/mo | n/a | | Pair with any VM created on demand (billed only while it exists). |

**Download time for 70 GB at failover.** I did not measure. At 50-100 MB/s sustained (typical for Hetzner/DO/AWS same-region-to-R2/B2 with rclone `--transfers 16`) that is 12-25 minutes; at 25 MB/s about 47 min. Add VM boot + docker pull: 2-3 min. So object-storage-plus-fresh-VM costs about $0.5-1/mo but means roughly 15-45 min to serve: worse than snapshot-restore (minutes) at about the same price, so use the object store only as a second copy.

## 3. Operational sketch (Oracle warm standby; the Hetzner variant in brackets)

Prepare (once, then a few times a year when DBs change):
- Image: push the 15 MB image to a registry (GHCR or Docker Hub), or `docker save | gzip` and `scp`; on the VM `docker load`. (Hetzner: bake it into the snapshot.)
- Data: `rsync -a --partial --inplace tcga.db tcgatargetgtex.db DEMO.db standby:/data/`. Verify with checksums, since the data must equal the home copy. Mount `:ro`.
- Run: `docker run -d --restart unless-stopped -v /data:/data:ro -p 127.0.0.1:8080:8080 ...`, with nginx in front. Note ARM: the image must be built for linux/arm64 (Go cross-compile is easy; build a multi-arch image). Hetzner CX line is x86 (CAX is ARM).

TLS:
- Simplest if proxied: Cloudflare Origin CA cert on the standby nginx, SSL mode Full (strict). 
- If staying DNS-only: Let's Encrypt on the standby. HTTP-01 needs port 80 reaching the standby with the right DNS, which is only true after the flip, so use DNS-01 via the Cloudflare API token (certbot-dns-cloudflare / lego). Then cert is valid for www.fiveprime.org before failover. Alternatively copy the GoDaddy cert and key to the standby (they are valid for the hostname; check expiry and renewal).

Failover:
- Automatic (watchdog): cron/systemd timer every 30 s curls `https://<home IP>/api/t2/health` (with `--resolve` to bypass DNS); 4 failures in a row => PATCH A record to standby IP, TTL 60. After home returns healthy for 10 min => flip back. Also push a notification (ntfy/Pushover/email) on each flip.
- Manual from phone (Hetzner path): a small script or a Cloudflare Worker URL "Start standby" that calls Hetzner API create-server-from-snapshot, then updates DNS once /health answers; or just do two taps in provider app + Cloudflare app.
- Failback: Check home is healthy, flip A record back, wait one TTL, then (Hetzner) re-snapshot if the data changed and delete the server.

Gotchas: standby IP must be static (Oracle reserved public IP is free; Hetzner create-from-snapshot gives a new IP unless a Primary IP is kept, which costs a little: not verified); set A record TTL to 60 s permanently (the 300 s TTL is the main latency); Shiny paths on the standby; the app should show its polite outage message (already built) if both are down.

## 3b. Two shapes, compared (added at Nathan's request)

**Shape 1, WARM: smallest VM running 24/7 with the 70 GB disk; traffic switched by Cloudflare LB or by a watchdog on the VM (no human).** Nothing has to be started, so there is no extra moving part beyond the health check/flip. Serving time: detection (about 1-2 min) + TTL (60-300 s) = roughly 2-6 min; with proxied LB, seconds.

**Shape 2, COLD: VM stopped (disk-only billing), started automatically.** Chain: something alive and external checks home (Cloudflare Health Check notification webhook, or, free-plan-safe, a Worker with a Cron Trigger doing the fetch every minute; I did not verify which plan Cloudflare Health Checks/notifications need, believed Pro+ (M)) -> Worker (free tier, M) calls the vendor start API -> poll standby `/health` -> Worker PATCHes the A record to the new IP -> failback (stop VM) via Worker or by hand. Extra complexity: a Worker (about 80-150 lines JS), a least-privilege API credential stored as a Worker secret (AWS IAM user allowed only `ec2:StartInstances`/`StopInstances` on that instance ARN, SigV4 signing in the Worker; GCP service account with `compute.instances.start` and a signed JWT; Azure service principal), state to avoid repeated start calls and flapping, and the public IP changing at each start unless you pay for a static one (AWS Elastic IP/public IPv4 is billed about $0.005/h, about $3.65/mo, M, which wipes out part of the saving; GCP a static external IP is billed when not in use, M). Boot-to-serving once started: EC2/GCE about 30-90 s to SSH-ready, plus Docker auto-start (`--restart unless-stopped`) and an empty SQLite page cache, so the first requests (each reads about 11,000 rows) are slower for a while (estimates, not measured). Total from decision: about 2-5 min including detection and TTL. Hetzner has a poweron API but a stopped server is billed in full, so for Hetzner cold means delete + recreate from snapshot (1-5 min, M/unmeasured) and the Worker must also handle server creation and a new IP.

**Which vendors make which shape cheap**
- Shape 1 cheap: Oracle ($0), Hetzner (EUR 5.5-8.5), Vultr/DO/Linode/Lightsail ($18-24, bundled disk, no cheaper way to hold 70 GB).
- Shape 2 cheap (stopped = disk only): AWS EC2 and GCP, Azure, Fly (volume only, about $9). Savings relative to warm: AWS about $13-25/mo, GCP about $10-12/mo; none beyond that for Hetzner, where warm is already about the price of cold elsewhere.
- Conclusion: where warm costs under about $9/mo (Hetzner, Oracle), shape 2 is not worth its complexity. Cold only pays off on AWS/GCP, and even there the saving is ~$150-250/yr against a Worker and credential to maintain.

**Cheapest viable warm standby per vendor, monthly (70 GB DB; 2 vCPU/4 GB preferred, but 2 GB suffices since the service idles at about 75 MB)**

| Vendor | Cheapest viable warm config | $/mo warm | $/mo cold (stopped) | Source quality |
|---|---|---|---|---|
| Oracle Always Free A1 | 2 OCPU/12 GB, 200 GB storage | 0 | n/a | V (reclamation risk) |
| Hetzner | CX23 2 vCPU/4 GB/40 GB EUR 5.49 + 30-40 GB volume (about $1.8-2.4, 3P $0.06/GB) = about EUR 7.5-8; or CX33 80 GB root EUR 8.49 (3P) | about EUR 8-8.5 (excl. VAT) | not applicable (stopped billed in full); snapshot-only about $1 but not auto-startable cheaply | CX23 V; volume, CX33 3P |
| Vultr | Regular 2 vCPU/4 GB/80 GB $20 | 20 | stopped billed in full; snapshot $3.5 | 3P |
| DigitalOcean | 2 GB/2 vCPU/60 GB $18 + 10 GB volume (about $1, M) | about 19 | snapshot $4.2 (destroy droplet) | V for $18, volume M |
| Linode | Shared 4 GB/80 GB $24 | 24 | billed in full | 3P |
| AWS Lightsail | 2 vCPU/4 GB/80 GB $24 | 24 | stopped billing UNVERIFIED (likely full) | V price |
| AWS EC2 | t4g.small (2 GB) about $12.3 + gp3 70 GB $5.6 = about $18 (t4g.medium about $30) | about 18 | about 5.6 (+ about 3.65 if static IP) | compute M, gp3 V as example |
| Google Cloud | e2-small about $12-13 + pd-balanced 70 GB about $7 | about 20 | about 7 | M, pages not readable |
| Azure | B2s-class about $30 + 128 GB disk about $18-20 | about 48-50 | about 18-20 | M, not researched |
| Fly.io | shared-cpu-2x 4 GB $13.39 + 70 GB volume about $9.0 (10 GB free) | about 22.4 | about 9.0 | V |

Money view per year: Oracle $0; Hetzner about EUR 100; AWS warm about $216 vs cold about $67-110; so cold saves at most about $100-150/yr on AWS/GCP versus Hetzner warm that is already about EUR 100/yr.

**Revised recommendation:** Shape 1. First choice Oracle Always Free warm (free, accept reclamation risk, keep Hetzner as the paid fallback); if Oracle fails, a Hetzner CX33 (about EUR 8.5/mo) warm with a watchdog flip. Pick shape 2 only if Nathan insists on AWS/GCP for non-price reasons.

## 4. Comparison

| Option | Running $/mo | Stopped $/mo | Time to serve after decision | Who acts | Complexity |
|---|---|---|---|---|---|
| Oracle Always Free warm + watchdog flip | 0 | n/a (always on) | 1-6 min (60-300 s TTL + detection) | nobody | medium; reclamation + capacity risk |
| Hetzner snapshot + manual flip | EUR 5.5-8.5 | about $1 (snapshot only) [3P price] | 5-15 min boot/restore plus TTL | Nathan | low |
| Hetzner always-on CX23/CX33 + watchdog | EUR 5.5-8.5 | same (stopped is billed) | 1-6 min | nobody | low-medium |
| Hetzner snapshot + Worker cron (health check, create server, flip DNS) | EUR 5.5-8.5 prorated hourly, only while up | about $1 | 6-20 min | nobody | high |
| Cloudflare LB ($5/mo, 2 origins; official table unverified) + any warm standby | +$5 | +$5 | seconds (proxied) | nobody | medium, plus proxy implications |
| AWS EC2 t4g.medium + gp3 | about 24.5 (M) | about 5.6-8 | 2 min + TTL | Nathan (or Lambda) | medium |
| Fly.io | 13.39 | about 9 | seconds-1 min + TTL | Nathan/script | medium |
| DigitalOcean / Vultr / Linode / Lightsail | 18-24 | 3.5-4.2 as snapshot-only (destroy droplet) | 5-15 min | Nathan | low |
| R2 or B2 copy + fresh VM | VM only | about $0.5-1.05 | 15-45 min | Nathan | medium |

## Open questions for Nathan
1. Is a 5-15 minute gap acceptable, or must the app never see an error? (Decides manual vs watchdog vs proxy+LB.)
2. Are you willing to move `www` behind Cloudflare's proxy (affects the Shiny sites, certificates, and hides the home IP)? Or keep DNS-only and live with the TTL?
3. Is the house outage typically hours? (Short outages favor automatic; rare long ones favor the cheap snapshot.)
4. Willing to create a PAYG Oracle account (card on file) to reduce reclamation risk, and to build an arm64 image?
5. Does the standby also need to answer the non-API paths on `www` with a "backup site" page, since the DNS flip moves everything under that hostname?
6. Current cert: how long until the GoDaddy cert expires, and can the key be copied to the standby?

## Not verified (honestly)
Cloudflare LB official per-origin/check/DNS-query table; Hetzner snapshot and volume per-GB prices and CX33 price from the vendor itself; Vultr and Linode prices from vendor pages; GCP, Azure and EC2 prices; Lightsail stopped-instance billing; Oracle PAYG exemption from reclamation and the A1 2/12 vs 4/24 limits; all download-time numbers (estimates, not measured).
