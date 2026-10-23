# Pending production change: Nginx API headers, logs, cache key

Prepared during the production freeze (nothing under /scratch/Docker was touched).
`nginx.conf.proposed` is a copy of `/scratch/Docker/Nginx/nginx.conf` with three edits;
`nginx-api-headers.patch` is `diff -u` of the two (made 2026-10-22). The proposed file passes
`nginx -t` in a throw-away container (same command `deploy.sh nginx` uses).

## What each hunk does

1. **Client address to the API.** The three `/api/t2/...` locations (`healthz`, `v1/contact`,
   `v1/`) set `proxy_set_header Connection ""`. Nginx inherits `proxy_set_header` from the
   server level only when the location sets none, so today the API gets no `X-Real-IP` /
   `X-Forwarded-For`: the contact form's 5-per-IP-per-day limit is global and the usage metrics
   see one client. Each location now repeats `X-Real-IP $remote_addr`,
   `X-Forwarded-For $proxy_add_x_forwarded_for` and `Host $host`.
2. **Error log.** `error_log /dev/stderr warn;` and `limit_req_log_level warn;` replace
   `/var/log/fiveprime.ssl.log` (a file that grows inside the container, outside the 20 MB x 5
   rotation of `docker logs`).
3. **Cache key.** `proxy_cache_key "$request_uri|$t2api_enc"` becomes
   `$uri|$arg_probes|$arg_probe|$arg_v|$arg_fill|$arg_q|$arg_limit|$arg_all|$t2api_enc`, so junk
   query parameters cannot fill the 4 GB cache. The list is every parameter the service reads
   (`grep -n 'Query()' service/cmd/t2api/main.go`: `v`, `all`, `q`, `limit`, `probes`, `probe`,
   `fill`). `typed` and `preset` appeared in the request but the service reads neither (`hits_typed`
   is a response field), so they are NOT in the key. `$arg_x` sees only the first occurrence, so
   two `if` lines refuse a request with a repeated `probes=` or `probe=` (400) instead of
   serving it from the wrong entry. Percent-encoded variants of the same request make separate
   keys (harmless, they stay bounded). If the service ever reads a new parameter, add it to the
   key in the same release.

## Apply (after Nathan lifts the freeze: delete `T2Mobile/ops/FREEZE`)

```
cp /scratch/nathan/R/T2/T2Mobile/ops/pending/nginx.conf.proposed /scratch/Docker/Nginx/nginx.conf
docker exec nginx-nginx-1 nginx -t       # note: tests the config IN the container; deploy.sh nginx tests the new file first
/scratch/nathan/R/T2/T2Mobile/ops/deploy.sh nginx
```
`deploy.sh nginx` backs up the running config as `nginx.conf.deploy-<stamp>`, tests the new file in
a throw-away container, copies it in and reloads; `deploy.sh rollback-nginx` puts the backup
back. Run `deploy.sh nginx-rebuild` later so the config also survives a container recreate.

## Verify

- `curl -s https://www.fiveprime.org/api/t2/statz` : `distinct_clients` grows with different
  callers (before: stays 1).
- A contact POST from two addresses (the LAN and a phone on cellular) is counted per address:
  the limit of 5 per IP per day applies to each, not to both together.
- `docker logs nginx-nginx-1 2>&1 | tail`: warnings and rate-limit rejections appear there.
- Cache: `curl -s -o /dev/null -D - 'https://www.fiveprime.org/api/t2/v1/TCGA/values?probes=CD8A&junk=1'`
  and again with `junk=2`: the second is a cache hit (same key); `probes=a&probes=b` gives 400.

## Two hardening items for Nathan's decision (not in the patch)

1. The Nginx container has no `cap_drop`, `no-new-privileges`, `read_only`, `pids_limit` or
   `mem_limit`, and the image is unpinned (`nginx:latest` in the Dockerfile). Proposed:
   pin the image by digest; `cap_drop: [ALL]` plus `NET_BIND_SERVICE` (ports 80/443) and what
   the image's entrypoint needs; `security_opt: [no-new-privileges:true]`; `read_only: true` with
   tmpfs for `/var/cache/nginx` (the 4 GB API cache would then live on a volume), `/var/run`,
   `/tmp`; `pids_limit`, `mem_limit`.
2. All apps share one flat Docker network (`shinypublic`): a compromised legacy Shiny app can
   reach `t2api:8080` and the HAProxy stats page. Proposed: one network per app group (the
   legacy Shiny apps on their own; Nginx attached to each; `t2api` only with Nginx, the pool
   and `t2api-web`), and the HAProxy stats page bound to its own network or removed.
