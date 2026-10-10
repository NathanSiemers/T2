# T2 API standby — a portable unit for a small hosted machine

Nathan, 2026-10-09: "a small backup server [must] reliably serve a dozen users, while not
choking in a DDoS scenario ... optimize such a single portable docker container that will
serve as a backup that we can place on another hosted service ... may only be a 4 GB RAM
server". This directory is that unit; the plan around it (which provider, the DNS flip, the
watchdog) is `../docs/FAILOVER-PLAN.md`.

## What it is

`docker-compose.yml` runs two containers on one small VM:

| | |
|---|---|
| `t2api` | the same image as at home (`t2api:2026.10`), tuned down: `-cache-mb 128`, `-db-conns 8`, `-mem-limit-mb 640`, `-max-inflight 32`; 1.5 CPUs, 1 GB ceiling, read-only, no capabilities |
| `nginx` | TLS, the `/api/t2/...` locations (`nginx/t2api.conf`), the "temporarily down" page for every other path (`nginx/down.html`); 256 MB ceiling |

Memory at rest: the service ≈ 80 MB + what it caches (128 MB per dataset at most), Nginx
≈ 10 MB. A 4 GB machine has room to spare; 2 GB would do.

## Why it does not choke under a flood

Three layers, each cheap, each measured (below):

1. **Nginx, per address**: 20 requests/s with a burst of 60 (`api_ip`), 10 connections
   (`conn_ip`), 1 contact message a minute. The rest get `429` without touching the service.
2. **Nginx, in total**: 200 requests/s, burst 400 (`api_all`, keyed by server name): more
   than this machine should ever be asked, so a *distributed* flood is turned away here.
   Short client timeouts (10 s header/body) and small header buffers keep slow-client
   attacks cheap; successful requests are not logged (the app's privacy policy), failures
   are.
3. **The service**: `-max-inflight 32` — a 33rd request at the same moment is refused at
   once with `503 Retry-After: 3` (`busy_refusals` in `/statz`); `/healthz` is exempt so a
   watchdog still sees the process. So a flood that gets through Nginx costs neither memory
   (32 × a 100-probe answer ≈ 200 MB at worst) nor disk time. The Go runtime's soft memory
   limit (640 MB) and Docker's hard ceiling (1 GB) sit above that; `restart: always` brings
   the process back if anything ever kills it.

What this cannot do: absorb a volumetric attack that fills the VM's network link. Only an
upstream proxy (Cloudflare in front of the record) does that; see `FAILOVER-PLAN.md`
"Upgrade if the gap matters".

## Setting it up on the VM

1. Docker + compose on an Ubuntu LTS VM (2 vCPU, 4 GB, 80 GB disk); firewall 22/80/443.
2. Data: copy the served directory (`/scratch/shinyusb/T2-data-<date>/`: `tcga.db` and
   `datasets/`, ≈ 67 GB, read-only) to `/srv/t2-data` (`rsync -a --partial`; hours at home
   upload speed — or from the R2 copy). The two files must carry the same `dataset_meta`
   keys as at home (the GTEx / TARGET parts), i.e. copy the directory that is live.
3. Image: `docker save t2api:2026.10 | ssh vm docker load` (15 MB), or build from this
   repository (`../service/Dockerfile`).
4. Certificate for `www.fiveprime.org` by DNS-01 through the Cloudflare API, so it exists
   before any DNS flip and renews itself:

       docker run --rm -v /etc/letsencrypt:/etc/letsencrypt -v /root/cf.ini:/cf.ini:ro certbot/dns-cloudflare \
           certonly --dns-cloudflare --dns-cloudflare-credentials /cf.ini -d www.fiveprime.org -d fiveprime.org \
           --agree-tos -m <address> --non-interactive
       # renewal: the same with `renew` from a weekly cron, then `docker compose exec nginx nginx -s reload`

   (`cf.ini`: `dns_cloudflare_api_token = <token with Zone:DNS:Edit for fiveprime.org only>`,
   mode 0600, outside the repository.)
5. `cd standby && T2_DATA=/srv/t2-data docker compose up -d`, then
   `curl https://www.fiveprime.org/api/t2/healthz --resolve www.fiveprime.org:443:<vm ip>`.
6. The watchdog that flips the DNS record (`FAILOVER-PLAN.md` step 4) runs on this VM too.
7. After each database rebuild at home: rsync the new directory up, change `T2_DATA`,
   `docker compose up -d`.

## Trying it at home (what was done on 2026-10-09)

The unit runs beside the real services on other ports, with the development image, my
database copies and a self-signed certificate:

    cd T2Mobile/standby
    T2_DATA=/scratch/nathan/R/T2-devdata T2_CERTS=/scratch/nathan/R/T2-devdata/standby-certs \
      docker compose -f docker-compose.yml -f /scratch/nathan/R/T2-devdata/standby-override.yml up -d
    curl -sk https://127.0.0.1:8443/api/t2/healthz
    docker run --rm --network host --entrypoint /loadtest t2api:dev -url https://127.0.0.1:8443/api/t2 -insecure \
        -dataset TCGA -c 12 -d 60s -think 10s -open          # a dozen scientists

(`/scratch/nathan/R/T2-devdata/stress_standby.sh` is the whole run.) The home server's disk
array is faster than a cloud VM's volume: uncached probes will take longer there (a cold
TCGA probe is ≈ 11,000 scattered reads); the cache, the hot-probe share and the in-flight
cap are what keep a small machine responsive.

## Measurements (2026-10-09, at home, t2api capped at 1.5 CPUs / 1 GB, nginx in front, TLS)

Load from `loadtest` (one address, 1–3 probes per request, half of them not yet cached);
"users" = clients that pause 10 s between requests, as a scientist at the app does.

| run | answered | latency median / p90 / p99 | service memory |
|---|---|---|---|
| 12 users, TCGA, opening the app first | 1.2/s, no errors | 45 / 79 / 119 ms | 168 MB |
| 100 users, TCGA, opening first | 10/s, no errors | 35 / 65 / 116 ms | 251 MB |
| 100 users, TCGA-TARGET-GTEx (19,131 samples per column) | 10/s, no errors | 68 / 145 / 397 ms | 599 MB |
| **flood**: 500 clients flat out, 80 % uncached probes | 20/s answered (the per-address allowance), **1,629,972 refused with 429 by Nginx in 60 s**; those answered: 79 / 161 / 220 ms | 737 MB peak; nginx 32 MB |
| 12 users right after the flood | no errors | 7 / 39 / 67 ms | 731 MB |

So: a dozen users are served in tens of milliseconds; a hundred still are; a flood from one
address is stopped at Nginx and the users behind it are unaffected. A distributed flood
(many addresses) meets the total cap (200/s) and, past Nginx, the service's in-flight cap:
at home the same image refused 844,000 of 1,000,000 requests in a minute from 1,000
flat-out clients, answering 2,700/s with 2.5 GB in use and a normal user's median of
6 ms right afterwards (`/scratch/nathan/R/T2-devdata/stress_home.log`).

Memory: the service's working set grows with its probe cache (128 MB per dataset here) up
to ≈ 740 MB under the 1 GB ceiling; on a 4 GB machine that leaves room for Nginx, Docker
and the page cache that makes uncached probes fast. Note Nginx logs every refused request
at `error` level: in a flood that is millions of lines, which is why the compose file caps
the container log at 3 × 10 MB.
