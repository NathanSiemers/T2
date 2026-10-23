# Pending production change: t2api -trusted-proxies and a shared -cache-mb

Prepared 2026-10-22 during the production freeze. Nothing under /scratch/Docker was touched.
Ships TOGETHER with the new t2api image (round-20261020 service changes) and pairs with the
Nginx header change in this directory (`nginx-api-headers.patch`, `README.md`).

## Why

Before this round the service believed `X-Real-IP` / `X-Forwarded-For` from any peer, so a client
that reached the service past Nginx could choose the address the contact limiter (5 per address
per day) and the /statz client counts keyed on. Now the service uses the TCP peer unless the peer
is inside `-trusted-proxies`.

## Compose change (t2api and t2api-web, /scratch/Docker/ShinyPublic/docker-compose.yml)

`t2api` sits on the user network `shinypublic` (`name: shinypublic`), which the compose file
declares without an `ipam`/subnet, so Docker picks the range and the file cannot name it. The
operator must fill it in:

    docker network inspect shinypublic --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
    # e.g. 172.18.0.0/16; use the subnet (or a narrower one holding only the Nginx container)

then add to the `command` of `t2api`:

    command: ["-addr", ":8080", "-datasets", "/data/datasets", "-cache-mb", "<see below>",
              "-trusted-proxies", "<shinypublic subnet>"]

Notes:
- The subnet also contains the Shiny containers. They send no X-Real-IP, so for them the peer
  address is used, which is correct. A narrower CIDR (Nginx's own container IP /32) is safer but
  breaks if the container is recreated with another IP; pin it with a static `ipv4_address` for
  Nginx if you want a /32.
- t2api-web (read only by the Shiny pool, no Nginx in front) needs no `-trusted-proxies`.
- If the flag is NOT passed with the new image, every request keys on Nginx's IP: the contact
  form allows 5 messages per day in all and /statz sees one client. So deploy image and flag
  together, and the Nginx headers (they carry the real address) at the same time.
- Verify after deploy: two contact POSTs from different outside addresses count separately,
  and `/statz` `usage` shows more than one distinct client.

## Cache memory (-cache-mb)

`-cache-mb` is now ONE budget shared by all datasets (it was 512 MB per dataset, 4 datasets, about
2 GB of columns plus SQLite page caches, close to the 4 GB container limit). Recommendation for
the 4-dataset production: keep `-cache-mb 1024` on `t2api` (hot columns of all four datasets
share 1 GB; the startup log prints the total) and `-cache-mb 512` on `t2api-web` if it has a
smaller memory limit. `-mem-limit-mb` (3072 default) can stay. Watch `/statz` `cache`
(`bytes`, `budget_bytes`, `evicted`): if `evicted` climbs fast under normal load, raise it.
