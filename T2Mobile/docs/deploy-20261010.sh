#!/bin/sh
## The production steps of 2026-10-10, in order, as commands (see PRODUCTION-SWITCH.md for
## the reasoning). Claude's auto mode was not allowed to run production deploys, so these
## are for Nathan to run (or to allow) step by step. Each step can be run on its own.
## Prerequisites done by Claude: /scratch/shinyusb/T2-data-20261010 (hard link to the
## unchanged tcga.db + a copy of the Toil database with the data-source keys applied);
## branch post-1.0 pushed; the T2T checkout can be switched to it.
set -e
step=${1:-help}
case $step in
service)   ## 1. the service: sources, preset counts, /probes?all=1, the in-flight cap
    docker tag t2api:2026.10 t2api:pre-sources-20261010
    docker build -t t2api:2026.10 /scratch/nathan/R/T2/T2Mobile/service
    cd /scratch/Docker/ShinyPublic && docker compose up -d t2api
    sleep 20; curl -s https://www.fiveprime.org/api/t2/healthz
    curl -s https://www.fiveprime.org/api/t2/v1/tcgatargetgtex/meta | grep -o '"sources":\[{"label":"[^"]*"' ;;
data)      ## 2. the databases: the data-source keys into the NEW copy (not served yet), then point
           ##    t2api, shiny-t2t and shiny-t2tc at the new directory
    docker run --rm -u 999:999 -v /scratch/nathan/R/T2:/srv/T2T:ro -v /scratch/shinyusb/T2-data-20261010/datasets:/data/datasets \
      -w /srv/T2T --entrypoint Rscript shinyt2t:2026.10 dataset_meta.R set /data/datasets/tcgatargetgtex.db \
      source_col=study 'sources=GTEX|TARGET' 'source_labels=GTEx|TARGET' \
      'source_descriptions=The GTEx study: normal tissues, and its EBV-transformed lymphocyte and fibroblast cell lines|The TARGET pediatric cancers'
    cd /scratch/Docker/ShinyPublic
    sed -i 's|/scratch/shinyusb/T2-data-20261005/|/scratch/shinyusb/T2-data-20261010/|g' docker-compose.yml
    grep -n "T2-data-2026" docker-compose.yml
    docker compose up -d t2api shiny-t2t shiny-t2tc ;;
code)      ## 3. the Shiny code: the post-1.0 branch into the served checkout (+ Thanos), restart
    cd /scratch/shinyusb/T2T && git fetch -q origin && git checkout -q post-1.0 && git pull -q --ff-only
    git log --oneline -1
    cd /scratch/Docker/ShinyPublic && docker compose restart shiny-t2t && scripts/pool.sh restart ;;
api-mode)  ## 3b. (optional) the sites read data through the service, no database mounts needed
    echo "add to shiny-t2t and shiny-t2tc in docker-compose.yml:"
    echo "    environment: {T2_API_URL: http://t2api:8080, T2_CONTACT_URL: http://t2api:8080/v1/contact}"
    echo "then: docker compose up -d shiny-t2t shiny-t2tc" ;;
nginx)     ## 4. /T2/ -> the pool; keep /T2T/ and /T2Tc/ for links in circulation
    cd /scratch/Docker/Nginx
    cp nginx.conf nginx.conf.pre-switch-20261010
    python3 - <<'PY'
s = open('nginx.conf').read()
old = "    location /T2/      { set $app shiny-t2;      proxy_pass http://$app:3838; }\n"
new = """    ## /T2/ is the new app (T2T code) served by the pool since 2026-10-10; the old app is archived
    location /T2/ {
        set $app haproxy-t2tc;
        proxy_pass http://$app:8080;
        proxy_cookie_path / /T2/;
        proxy_cookie_flags T2TC secure samesite=lax;
    }
"""
assert old in s; open('nginx.conf', 'w').write(s.replace(old, new, 1))
PY
    docker cp nginx.conf nginx-nginx-1:/etc/nginx/nginx.conf && docker exec nginx-nginx-1 nginx -t && docker exec nginx-nginx-1 nginx -s reload
    curl -s -o /dev/null -w 'https://www.fiveprime.org/T2/ -> %{http_code}\n' https://www.fiveprime.org/T2/ ;;
archive)   ## 5. stop the old app and archive its directory (code + the July databases, 60 GB)
    cd /scratch/Docker/ShinyPublic && docker compose stop shiny-t2 && docker compose rm -f shiny-t2
    mv /scratch/shinyusb/T2 /scratch/shinyusb/T2.archive-20261010
    rm -f /scratch/shinyusb/T2T/tcga.db /scratch/shinyusb/T2T/datasets   # stale symlinks into the old directory
    echo "now comment the shiny-t2 service out of docker-compose.yml and the T2 entry out of scripts/deploy.sh" ;;
check)     ## 6. the browser suite against the live site
    docker run --rm --network shinypublic -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 \
      -e NOT_CRAN=true -e CHROMOTE_CHROME=/home/rstudio/R/T2-devdata/chrome/chrome-headless-shell-linux64/chrome-headless-shell \
      -e T2_SITE_URL=https://www.fiveprime.org/T2/ --entrypoint Rscript rstudio:2026.03 test_browser_suite.R /home/rstudio/R/T2-devdata/screenshots/shiny-live ;;
*) sed -n '2,8p' "$0"; grep -E '^[a-z-]+\)' "$0" ;;
esac
