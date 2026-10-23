#!/bin/sh
## deploy.sh — the production deploy steps for the T2 sites and the t2api service, one per
## argument, each safe to run on its own and to run again. Nathan (2026-10-11): "I don't want
## to have to type this by hand again. give yourself the permissions to do this in the future
## and the right script to do it." Claude's Claude Code settings allow this script by path.
##
##   ops/deploy.sh service            rebuild the t2api image from the repo, tag the old one, restart
##   ops/deploy.sh data-stage <YYYYMMDD> [<name>.db ...]
##                                    stage a NEW data directory /scratch/shinyusb/T2-data-<YYYYMMDD>/
##                                    from the served one: tcga.db and every dataset not named are
##                                    hard links to the served files (same inodes, never written);
##                                    each named file is copied from the repo's datasets/ under a
##                                    .staging name, byte-compared, quick_checked, renamed into place
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
##   ops/deploy.sh api-mode off <backup>   restore a named compose backup (the current file is saved first)
##
## FREEZE: while T2Mobile/ops/FREEZE exists every mutating step (all but status, check and
## the staging step) prints the file and exits 2. T2_COMPOSE_FILE=<copy> points data-stage/data/status at a
## copy of the compose file and T2_DATA_BASE at a scratch base (dry runs); with it set, `data` edits
## the copy and starts nothing.
##
## Where things are: /scratch/Docker/ShinyPublic (compose: shiny-t2t, shiny-t2tc pool, haproxy,
## t2api; scripts/deploy.sh, scripts/pool.sh), /scratch/Docker/Nginx (the site config, built into
## the image at /etc/nginx/conf.d/nginx.conf; the top-level /etc/nginx/nginx.conf is the image's
## stock file and is never replaced), /scratch/shinyusb/T2T (the served checkout, on main).
set -eu
PUB=/scratch/Docker/ShinyPublic
NGX=/scratch/Docker/Nginx
REPO=/scratch/nathan/R/T2
COMPOSE=${T2_COMPOSE_FILE:-$PUB/docker-compose.yml}
DBASE=${T2_DATA_BASE:-/scratch/shinyusb}
SELF=$(cd "$(dirname "$0")" && pwd)
step=${1:-help}
stamp=$(date +%Y%m%d-%H%M%S)
## the production freeze: a file next to this script; Nathan lifts it by deleting the file
case $step in
service|data|code|nginx|nginx-rebuild|pool-restart|api-mode|fix-links|rollback-*|retire-*)
    if [ -f "$SELF/FREEZE" ]; then cat "$SELF/FREEZE"; echo "(deploy.sh $step refused: $SELF/FREEZE exists)"; exit 2; fi ;;
esac
## health: the public healthz must answer 200 within 60 s, else fail loudly with the rollback line
health() {   # $1 = rollback line
    i=0; c=000
    while [ "$i" -lt 12 ]; do
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://www.fiveprime.org/api/t2/healthz || true)
        if [ "$c" = 200 ]; then echo "healthz: 200"; return 0; fi
        i=$((i + 1)); sleep 5
    done
    echo "FAILED: healthz did not answer 200 within 60 s (last status $c)"; echo "rollback: $1"; exit 1
}
case $step in
service)
    ## Clean release only (Nathan, 2026-10-22: "let's be clean about this in terms of development versions,
    ## PRs etc."): the image is built from the SERVED checkout ($SRV, on main), never from the development
    ## repo, and only when that checkout is clean and equal to origin/main. The image also gets a
    ## t2api:git-<sha> tag so `docker ps` tells which commit production runs.
    ## Override for an emergency hotfix branch: T2_DEPLOY_REF=<branch> (still must be clean and pushed).
    SRV=${T2_SERVED_CHECKOUT:-/scratch/shinyusb/T2T}
    want=${T2_DEPLOY_REF:-main}
    [ -d "$SRV/.git" ] || { echo "no git checkout at $SRV"; exit 1; }
    br=$(git -C "$SRV" rev-parse --abbrev-ref HEAD)
    [ "$br" = "$want" ] || { echo "$SRV is on $br, not $want (deploy.sh code pulls main there first)"; exit 1; }
    dirty=$(git -C "$SRV" status --porcelain --untracked-files=no)
    [ -z "$dirty" ] || { echo "$SRV has uncommitted changes; a release image is built from a clean checkout only:"; echo "$dirty"; exit 1; }
    git -C "$SRV" fetch -q origin "$want"
    local_sha=$(git -C "$SRV" rev-parse HEAD); remote_sha=$(git -C "$SRV" rev-parse "origin/$want")
    [ "$local_sha" = "$remote_sha" ] || { echo "$SRV ($local_sha) differs from origin/$want ($remote_sha): run deploy.sh code first"; exit 1; }
    short=$(git -C "$SRV" rev-parse --short=10 HEAD)
    tag="t2api:pre-$stamp"
    if docker image inspect "$tag" >/dev/null 2>&1; then echo "$tag exists; not overwriting"; exit 1; fi
    rb="docker tag $tag t2api:2026.10 && (cd $PUB && docker compose up -d t2api t2api-web)"
    docker tag t2api:2026.10 "$tag"
    echo "building t2api from $SRV @ $short ($want)"
    docker build -q --label "org.opencontainers.image.revision=$local_sha" -t t2api:2026.10 -t "t2api:git-$short" "$SRV/T2Mobile/service"
    (cd "$PUB" && docker compose up -d t2api t2api-web)     # t2api-web: the web app's own instance (2026-10-20)
    health "$rb"
    curl -s https://www.fiveprime.org/api/t2/v1/datasets | grep -o '"name":"[^"]*"' | tr '\n' ' '; echo
    echo "released: t2api:git-$short ($want $local_sha)"
    echo "rollback: $rb" ;;
data-stage)
    ## T2_DATA_BASE overrides the base directory for a dry run on scratch space
    base=$DBASE
    date=${2:?usage: deploy.sh data-stage YYYYMMDD [name.db ...]   (files from $REPO/datasets/)}; shift 2
    ## the served directory is named in the compose file; the name may carry a letter suffix (T2-data-20261020b)
    cur=$(grep -o "$base/T2-data-[A-Za-z0-9_-]*" "$COMPOSE" | sort -u || true)
    [ -n "$cur" ] || { echo "no $base/T2-data-* directory named in $COMPOSE"; exit 1; }
    [ "$(printf '%s\n' "$cur" | grep -c .)" = 1 ] || { echo "the compose file names more than one T2-data directory:"; echo "$cur"; exit 1; }
    [ -d "$cur/datasets" ] || { echo "served data directory not found ($cur)"; exit 1; }
    echo "served directory (from $COMPOSE): $cur"
    new="$base/T2-data-$date"
    [ ! -e "$new" ] || { echo "$new exists; a staging directory is never reused"; exit 1; }
    for f in "$@"; do
        [ -f "$REPO/datasets/$f" ] || { echo "no $REPO/datasets/$f"; exit 1; }
        ## a single-file copy of a WAL-mode db would miss the un-checkpointed pages
        [ ! -e "$REPO/datasets/$f-wal" ] || { echo "$f has a -wal sidecar: checkpoint it first"; exit 1; }
        jm=$(sqlite3 -readonly "$REPO/datasets/$f" "PRAGMA journal_mode;"); [ "$jm" = delete ] || { echo "$f: journal_mode is $jm, not delete"; exit 1; }
    done
    ## everything to be linked from the served directory must exist before anything is created
    nlink=0
    for p in "$cur"/datasets/*.db; do
        [ -f "$p" ] || { echo "no dataset file in $cur/datasets (matched: $p)"; exit 1; }
        nlink=$((nlink + 1))
    done
    [ -f "$cur/datasets/TCGA.db" ] || [ -f "$cur/tcga.db" ] || { echo "neither $cur/datasets/TCGA.db nor $cur/tcga.db exists"; exit 1; }
    mkdir -p "$new/datasets"
    ## the TCGA file is datasets/TCGA.db (2026-10-19); a legacy served dir has it as tcga.db at the top
    if [ -f "$cur/datasets/TCGA.db" ]; then src_tcga="$cur/datasets/TCGA.db"; else src_tcga="$cur/tcga.db"; fi
    named_tcga=0; for f in "$@"; do [ "$f" = TCGA.db ] && named_tcga=1; done
    [ $named_tcga = 1 ] || [ -f "$cur/datasets/TCGA.db" ] || ln "$src_tcga" "$new/datasets/TCGA.db"
    for p in "$cur"/datasets/*.db; do
        b=$(basename "$p"); skip=0
        for f in "$@"; do [ "$f" = "$b" ] && skip=1; done
        [ $skip = 1 ] || ln "$p" "$new/datasets/$b"
    done
    for f in "$@"; do
        src="$REPO/datasets/$f"; dst="$new/datasets/$f"
        cp "$src" "$dst.staging"
        cmp "$src" "$dst.staging" || { echo "copy of $f differs from the source"; exit 1; }
        chk=$(sqlite3 -readonly "$dst.staging" "PRAGMA quick_check;" | head -1)
        [ "$chk" = ok ] || { echo "$f: quick_check says $chk"; exit 1; }
        mv "$dst.staging" "$dst"
        printf '%-28s %s samples\n' "$f" "$(sqlite3 -readonly "$dst" 'SELECT COUNT(*) FROM samples')"
    done
    ## what is in the staged directory: name, size, inode, where it came from
    printf '%-28s %14s %12s  %s\n' file bytes inode source
    for p in "$new"/datasets/*.db; do
        b=$(basename "$p"); src="copied from $REPO/datasets"
        for q in "$cur/datasets/$b" "$cur/tcga.db"; do
            [ -f "$q" ] && [ "$(stat -c %i "$q")" = "$(stat -c %i "$p")" ] && src="hard link of $q"
        done
        printf '%-28s %14s %12s  %s\n' "$b" "$(stat -c %s "$p")" "$(stat -c %i "$p")" "$src"
    done
    echo "staged. next: $0 data $new" ;;
data)
    dir=${2:?usage: deploy.sh data /scratch/shinyusb/T2-data-YYYYMMDD}; dir=${dir%/}
    [ -d "$dir/datasets" ] && { [ -f "$dir/datasets/TCGA.db" ] || [ -f "$dir/tcga.db" ]; } || { echo "$dir must hold datasets/ with TCGA.db (or a legacy top-level tcga.db)"; exit 1; }
    curs=$(grep -o "$DBASE/T2-data-[A-Za-z0-9_-]*" "$COMPOSE" | sort -u || true)
    [ -n "$curs" ] || { echo "no T2-data directory found in $COMPOSE"; exit 1; }
    [ "$(printf '%s\n' "$curs" | grep -c .)" = 1 ] || { echo "the compose file names more than one T2-data directory:"; echo "$curs"; exit 1; }
    cur=$curs
    [ "$cur" = "$dir" ] && { echo "already on $dir"; exit 0; }
    cp "$COMPOSE" "$COMPOSE.pre-data-$stamp"
    sed -i "s|$cur/|$dir/|g" "$COMPOSE"
    ## the switch must have happened: the new directory is named, the old one is gone
    if ! grep -qF "$dir/" "$COMPOSE" || grep -qF "$cur/" "$COMPOSE"; then
        echo "FAILED: after the edit $COMPOSE does not name only $dir/ (was $cur/)"
        echo "restore: cp $COMPOSE.pre-data-$stamp $COMPOSE"; exit 1
    fi
    if [ -f "$dir/datasets/TCGA.db" ]; then   # new layout: no top-level mount, no -tcga flag (the service finds datasets/TCGA.db)
        sed -i "\|$dir/tcga.db:/data/tcga.db:ro|d" "$COMPOSE"
        sed -i 's|"-tcga", "/data/tcga.db", ||' "$COMPOSE"
    fi
    grep -n "T2-data-" "$COMPOSE"
    if [ -n "${T2_COMPOSE_FILE:-}" ]; then echo "dry run on $COMPOSE: nothing restarted"; exit 0; fi
    (cd "$PUB" && docker compose up -d t2api t2api-web shiny-t2t shiny-t2tc)
    echo "rollback: cp $COMPOSE.pre-data-$stamp $COMPOSE && (cd $PUB && docker compose up -d t2api t2api-web shiny-t2t shiny-t2tc)" ;;
code)
    cd /scratch/shinyusb/T2T
    old=$(git rev-parse HEAD)
    echo "served commit now: $(git log --oneline -1)"
    echo "rollback: git -C /scratch/shinyusb/T2T checkout $old && $PUB/scripts/deploy.sh T2T"
    git fetch -q origin && git checkout -q main && git pull -q --ff-only && git log --oneline -1
    "$PUB/scripts/deploy.sh" T2T ;;
nginx)
    cd "$NGX"
    ## back up what the RUNNING container has (it may differ from the image after an earlier cp)
    docker cp nginx-nginx-1:/etc/nginx/conf.d/nginx.conf "nginx.conf.deploy-$stamp"
    [ -s "nginx.conf.deploy-$stamp" ] || { rm -f "nginx.conf.deploy-$stamp"; echo "the backup of the running config is empty; nothing changed"; exit 1; }
    docker run --rm -v "$PWD/nginx.conf:/etc/nginx/conf.d/nginx.conf:ro" -v "$PWD/data/certs:/etc/nginx/certs:ro" --entrypoint nginx nginx-nginx -t
    docker cp nginx.conf nginx-nginx-1:/etc/nginx/conf.d/nginx.conf
    docker exec nginx-nginx-1 nginx -t && docker exec nginx-nginx-1 nginx -s reload
    for u in https://www.fiveprime.org/T2/ https://fiveprime.org/T2/ https://www.fiveprime.org/T2T/ https://www.fiveprime.org/api/t2/healthz; do
        printf '%-40s ' "$u"; curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$u"; done
    echo "rollback: $0 rollback-nginx   (uses nginx.conf.deploy-$stamp)";;
nginx-rebuild)
    cd "$NGX" && docker compose up -d --build && sleep 3 && docker exec nginx-nginx-1 nginx -t ;;
pool-restart)
    "$PUB/scripts/pool.sh" restart ;;
status)
    docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'shiny-t2|haproxy-t2tc|t2api|nginx' | sort
    printf 'served T2T code: '; git -C /scratch/shinyusb/T2T log --oneline -1
    printf 'data directory:  '; grep -o "$DBASE/T2-data-[A-Za-z0-9_-]*" "$COMPOSE" | sort -u | tr '\n' ' '; echo
    for u in https://fiveprime.org/T2/ https://www.fiveprime.org/T2T/ https://www.fiveprime.org/T2Tc/ https://www.fiveprime.org/api/t2/healthz; do
        printf '%-40s ' "$u"; curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$u"; done ;;
check)
    ## screenshots: the host directory below is /home/rstudio/R/T2-devdata/... inside the container
    ## T2_CONTACT_URL names the live contact endpoint so the suite expects the contact form (the sites
    ## are in api-mode); the suite never submits it (test_browser_suite.R, header)
    d=/scratch/nathan/R/T2-devdata/screenshots/shiny-live; mkdir -m 777 -p "$d"; rm -f "${d:?}"/*
    docker run --rm --network shinypublic -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 \
      -e NOT_CRAN=true -e CHROMOTE_CHROME=/home/rstudio/R/T2-devdata/chrome/chrome-headless-shell-linux64/chrome-headless-shell \
      -e T2_SITE_URL=https://www.fiveprime.org/T2/ -e T2_CONTACT_URL=https://www.fiveprime.org/api/t2/v1/contact \
      --entrypoint Rscript rstudio:2026.03 test_browser_suite.R \
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
fix-links)   ## the served checkout reaches the databases through two symlinks that resolve INSIDE the
             ## containers to the data mount (/srv/shiny-server/T2/ = the T2-data directory); on the host
             ## they look stale (they point into the archived T2 directory) -- never remove them
    cd /scratch/shinyusb/T2T && ln -sfn ../T2/tcga.db tcga.db && ln -sfn ../T2/datasets datasets && ls -la tcga.db datasets
    docker exec shinypublic-shiny-t2tc-1 ls -la /srv/shiny-server/T2T/tcga.db /srv/shiny-server/T2T/datasets/ | head -3 ;;
api-mode)    ## the sites read through the service instead of the database files
             ##   api-mode canary   shiny-t2t only (serves nobody since /T2T/ redirects; test it on 127.0.0.1:3857/T2T/)
             ##   api-mode pool     the T2Tc pool (= the public /T2/)
             ##   api-mode off      back to the files (restores the backup of the compose file)
    cd "$PUB"; what=${2:?usage: deploy.sh api-mode canary|pool|off}
    case $what in
    off)  bk=${3:-}
          if [ -z "$bk" ] || [ ! -f "$bk" ]; then
              echo "usage: deploy.sh api-mode off <backup file>   (a docker-compose.yml.pre-apimode-* in $PUB)"
              echo "backups, newest first:"; ls -t docker-compose.yml.pre-apimode-* 2>/dev/null || echo "  (none)"
              echo "(the file-mode one is usually the oldest; the current compose file is saved first)"; exit 1
          fi
          cp docker-compose.yml "docker-compose.yml.pre-apimodeoff-$stamp"
          cp "$bk" docker-compose.yml && docker compose up -d shiny-t2t shiny-t2tc && echo "restored $bk (previous file: docker-compose.yml.pre-apimodeoff-$stamp)" ;;
    canary|pool)
          svc=shiny-t2t; [ "$what" = pool ] && svc=shiny-t2tc
          ## Shiny Server starts its R workers with its own environment: a compose `environment:`
          ## never reaches the app. R reads Renviron.site at start-up, so the image's own file plus
          ## the two variables is mounted over it (a file mount over an existing file works on the
          ## read-only root; a new file in the read-only checkout or home does not)
          { docker run --rm --entrypoint cat shinyt2t:2026.10 /usr/local/lib/R/etc/Renviron.site
            printf '## api-mode (ops/deploy.sh): the data layer is the t2api service\nT2_API_URL=http://t2api:8080\nT2_CONTACT_URL=http://t2api:8080/v1/contact\n'; } > conf/t2-api-mode.Renviron.site
          cp docker-compose.yml "docker-compose.yml.pre-apimode-$stamp"
          python3 - "$svc" <<'PY'
import re, sys
svc = sys.argv[1]
c = open('docker-compose.yml').read()
m = re.search(r'(?ms)^  %s:\n.*?(?=^  ## |^  [a-z][a-z0-9-]*:\n|\Z)' % re.escape(svc), c)
block = m.group(0)
if 'T2_API_URL' in block: print(svc + ': already in api-mode'); sys.exit(0)
new = block
# the data volumes go (the app needs no files over the service); the code mounts stay
new = re.sub(r'(?m)^      - /scratch/shinyusb/T2-data-[0-9]+/tcga\.db:[^\n]*\n', '', new)
new = re.sub(r'(?m)^      - /scratch/shinyusb/T2-data-[0-9]+/datasets:[^\n]*\n', '', new)
env = ('    ## api-mode (2026-10-11): the data layer is the t2api service on this network; no\n'
       '    ## database files are mounted (t2_api_client.R); the contact form posts to the service too.\n'
       '    ## Shiny Server does not pass the container environment to R: the variables are in the\n'
       '    ## Renviron.site mounted below (conf/t2-api-mode.Renviron.site = the image file + them)\n')
renv = '      - ./conf/t2-api-mode.Renviron.site:/usr/local/lib/R/etc/Renviron.site:ro\n'
new = new.replace('    volumes:\n', env + '    volumes:\n' + renv, 1)
open('docker-compose.yml', 'w').write(c.replace(block, new, 1)); print(svc + ': api-mode set, data volumes removed')
PY
          docker compose config --quiet && docker compose up -d "$svc"
          sleep 25
          if [ "$what" = canary ]; then curl -s -o /dev/null -w 'canary http://127.0.0.1:3857/T2T/ -> %{http_code}\n' http://127.0.0.1:3857/T2T/
          else curl -s -o /dev/null -w 'https://www.fiveprime.org/T2/ -> %{http_code}\n' https://www.fiveprime.org/T2/; fi
          echo "rollback: $0 api-mode off" ;;
    esac ;;
rollback-service)
    last=$(docker image ls --format '{{.Repository}}:{{.Tag}} {{.CreatedAt}}' | grep '^t2api:pre-' | sort -k2 -r | head -1 | cut -d' ' -f1)
    [ -n "$last" ] || { echo "no t2api:pre-* image"; exit 1; }
    echo "restoring $last"; docker tag "$last" t2api:2026.10 && (cd "$PUB" && docker compose up -d t2api t2api-web)
    health "inspect: docker logs t2api" ;;
rollback-nginx)
    cd "$NGX"; last=$(ls -t nginx.conf.deploy-* 2>/dev/null | head -1)
    [ -n "$last" ] || { echo "no nginx.conf.deploy-* backup"; exit 1; }
    [ -s "$last" ] || { echo "$last is empty"; exit 1; }
    echo "restoring $last"; docker cp "$last" nginx-nginx-1:/etc/nginx/conf.d/nginx.conf && docker exec nginx-nginx-1 nginx -t && docker exec nginx-nginx-1 nginx -s reload ;;
*)  sed -n '2,32p' "$0" ;;
esac
