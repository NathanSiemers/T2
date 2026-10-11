#!/bin/sh
## deploy.sh — the production deploy steps for the T2 sites and the t2api service, one per
## argument, each safe to run on its own and to run again. Nathan (2026-10-11): "I don't want
## to have to type this by hand again. give yourself the permissions to do this in the future
## and the right script to do it." Claude's Claude Code settings allow this script by path.
##
##   ops/deploy.sh service            rebuild the t2api image from the repo, tag the old one, restart
##   ops/deploy.sh data <dir>         point t2api, shiny-t2t and the pool at a NEW data directory
##                                    (never a write to a served file; the directory must hold
##                                    tcga.db and datasets/ with the dataset_meta keys applied)
##   ops/deploy.sh code               pull main into the served checkout, restart T2T and the pool
##   ops/deploy.sh nginx              copy the host nginx.conf into the running container (conf.d),
##                                    test, reload (no restart, no dropped sessions)
##   ops/deploy.sh nginx-rebuild      rebuild the Nginx image so the config survives a recreate
##                                    (restarts Nginx: a few seconds for every site)
##   ops/deploy.sh pool-restart       restart the pool instances (new shiny-server conf, new code)
##   ops/deploy.sh status             what is running, what each serves, the live answers
##   ops/deploy.sh check              the Chrome suite against the live /T2/ (page reads only)
##   ops/deploy.sh rollback-service   the previous t2api image back
##   ops/deploy.sh rollback-nginx     the pre-change site config back into the container
##
## Where things are: /scratch/Docker/ShinyPublic (compose: shiny-t2t, shiny-t2tc pool, haproxy,
## t2api; scripts/deploy.sh, scripts/pool.sh), /scratch/Docker/Nginx (the site config, built into
## the image at /etc/nginx/conf.d/nginx.conf; the top-level /etc/nginx/nginx.conf is the image's
## stock file and is never replaced), /scratch/shinyusb/T2T (the served checkout, on main).
set -eu
PUB=/scratch/Docker/ShinyPublic
NGX=/scratch/Docker/Nginx
REPO=/scratch/nathan/R/T2
step=${1:-help}
stamp=$(date +%Y%m%d-%H%M)
case $step in
service)
    docker tag t2api:2026.10 "t2api:pre-$stamp"
    docker build -q -t t2api:2026.10 "$REPO/T2Mobile/service"
    (cd "$PUB" && docker compose up -d t2api)
    sleep 15; printf 'healthz: '; curl -s https://www.fiveprime.org/api/t2/healthz
    curl -s https://www.fiveprime.org/api/t2/v1/datasets | grep -o '"name":"[^"]*"' | tr '\n' ' '; echo
    echo "rollback: docker tag t2api:pre-$stamp t2api:2026.10 && (cd $PUB && docker compose up -d t2api)" ;;
data)
    dir=${2:?usage: deploy.sh data /scratch/shinyusb/T2-data-YYYYMMDD}
    [ -f "$dir/tcga.db" ] && [ -d "$dir/datasets" ] || { echo "$dir must hold tcga.db and datasets/"; exit 1; }
    cur=$(grep -o '/scratch/shinyusb/T2-data-[0-9]*' "$PUB/docker-compose.yml" | head -1)
    [ -n "$cur" ] || { echo "no T2-data directory found in $PUB/docker-compose.yml"; exit 1; }
    [ "$cur" = "$dir" ] && { echo "already on $dir"; exit 0; }
    cp "$PUB/docker-compose.yml" "$PUB/docker-compose.yml.pre-data-$stamp"
    sed -i "s|$cur/|$dir/|g" "$PUB/docker-compose.yml"
    grep -n "T2-data-" "$PUB/docker-compose.yml"
    (cd "$PUB" && docker compose up -d t2api shiny-t2t shiny-t2tc)
    echo "rollback: cp $PUB/docker-compose.yml.pre-data-$stamp $PUB/docker-compose.yml && (cd $PUB && docker compose up -d t2api shiny-t2t shiny-t2tc)" ;;
code)
    cd /scratch/shinyusb/T2T && git fetch -q origin && git checkout -q main && git pull -q --ff-only && git log --oneline -1
    "$PUB/scripts/deploy.sh" T2T ;;
nginx)
    cd "$NGX"
    docker run --rm --entrypoint cat nginx-nginx /etc/nginx/conf.d/nginx.conf > "nginx.conf.pre-$stamp"   # what the container was built with
    docker run --rm -v "$PWD/nginx.conf:/etc/nginx/conf.d/nginx.conf:ro" -v "$PWD/data/certs:/etc/nginx/certs:ro" --entrypoint nginx nginx-nginx -t
    docker cp nginx.conf nginx-nginx-1:/etc/nginx/conf.d/nginx.conf
    docker exec nginx-nginx-1 nginx -t && docker exec nginx-nginx-1 nginx -s reload
    for u in https://www.fiveprime.org/T2/ https://fiveprime.org/T2/ https://www.fiveprime.org/T2T/ https://www.fiveprime.org/api/t2/healthz; do
        printf '%-40s ' "$u"; curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$u"; done
    echo "rollback: $0 rollback-nginx   (uses nginx.conf.pre-$stamp)";;
nginx-rebuild)
    cd "$NGX" && docker compose up -d --build && sleep 3 && docker exec nginx-nginx-1 nginx -t ;;
pool-restart)
    "$PUB/scripts/pool.sh" restart ;;
status)
    docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'shiny-t2|haproxy-t2tc|t2api|nginx' | sort
    printf 'served T2T code: '; git -C /scratch/shinyusb/T2T log --oneline -1
    printf 'data directory:  '; grep -o '/scratch/shinyusb/T2-data-[0-9]*' "$PUB/docker-compose.yml" | sort -u | tr '\n' ' '; echo
    for u in https://fiveprime.org/T2/ https://www.fiveprime.org/T2T/ https://www.fiveprime.org/T2Tc/ https://www.fiveprime.org/api/t2/healthz; do
        printf '%-40s ' "$u"; curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$u"; done ;;
check)
    ## screenshots: the host directory below is /home/rstudio/R/T2-devdata/... inside the container
    d=/scratch/nathan/R/T2-devdata/screenshots/shiny-live; mkdir -m 777 -p "$d"; rm -f "${d:?}"/*
    docker run --rm --network shinypublic -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 \
      -e NOT_CRAN=true -e CHROMOTE_CHROME=/home/rstudio/R/T2-devdata/chrome/chrome-headless-shell-linux64/chrome-headless-shell \
      -e T2_SITE_URL=https://www.fiveprime.org/T2/ --entrypoint Rscript rstudio:2026.03 test_browser_suite.R \
      /home/rstudio/R/T2-devdata/screenshots/shiny-live 2>&1 | grep -E "PASS|FAIL|Error|done" ;;
retire-t2)   ## after the archive step: take the old shiny-t2 out of the compose file and of scripts/deploy.sh
    cd "$PUB"
    python3 - <<'PY'
import re, shutil, datetime
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M')
c = open('docker-compose.yml').read()
if re.search(r'(?m)^  shiny-t2:\n', c):
    shutil.copy('docker-compose.yml', 'docker-compose.yml.pre-retire-' + stamp)
    m = re.search(r'(?ms)^  shiny-t2:\n.*?(?=^  ## |^  [a-z][a-z0-9-]*:\n)', c)
    block = m.group(0)
    c = c.replace(block, ''.join('  ## ' + l if l.strip() else l for l in block.splitlines(True)), 1)
    open('docker-compose.yml', 'w').write(c); print('docker-compose.yml: shiny-t2 commented out (backup docker-compose.yml.pre-retire-%s)' % stamp)
else: print('docker-compose.yml: shiny-t2 already gone')
d = open('scripts/deploy.sh').read()
d2 = d.replace('    T2) echo shiny-t2 ;; T2T)', '    T2T)').replace('    T2) echo 3851 ;; AllNets)', '    AllNets)').replace('set -- T2 T2T AllNets', 'set -- T2T AllNets')
d2 = d2.replace('##     scripts/deploy.sh <App> [<App> ...]    # T2 T2T AllNets', '##     scripts/deploy.sh <App> [<App> ...]    # T2T AllNets')
if d2 != d:
    shutil.copy('scripts/deploy.sh', 'scripts/deploy.sh.pre-retire-' + stamp); open('scripts/deploy.sh', 'w').write(d2); print('scripts/deploy.sh: T2 entry removed')
else: print('scripts/deploy.sh: no T2 entry')
PY
    docker compose config --quiet && echo "compose file still valid" ;;
rollback-service)
    last=$(docker image ls --format '{{.Repository}}:{{.Tag}} {{.CreatedAt}}' | grep '^t2api:pre-' | sort -k2 -r | head -1 | cut -d' ' -f1)
    [ -n "$last" ] || { echo "no t2api:pre-* image"; exit 1; }
    echo "restoring $last"; docker tag "$last" t2api:2026.10 && (cd "$PUB" && docker compose up -d t2api) ;;
rollback-nginx)
    cd "$NGX"; last=$(ls -t nginx.conf.pre-* 2>/dev/null | head -1)
    [ -n "$last" ] || { echo "no nginx.conf.pre-* backup"; exit 1; }
    echo "restoring $last"; docker cp "$last" nginx-nginx-1:/etc/nginx/conf.d/nginx.conf && docker exec nginx-nginx-1 nginx -t && docker exec nginx-nginx-1 nginx -s reload ;;
*)  sed -n '2,24p' "$0" ;;
esac
