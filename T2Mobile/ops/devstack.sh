#!/bin/sh
## devstack.sh -- named development instances of the t2api service, beside the canonical t2api-dev.
## One instance per piece of work in flight: a rebuild for one branch never stops a suite that is
## running against another. Nathan (2026-10-22): "you really should have a good development
## environment available for testing".
##
##   ops/devstack.sh up <name> [port]       build the image from THIS checkout as t2api:<name> and start
##                                          container t2api-<name> on 127.0.0.1:<port> (default 3870+),
##                                          network t2api-<name>, dev data + contact dir like t2api-dev
##   ops/devstack.sh down <name>            stop and remove it (image kept)
##   ops/devstack.sh ls                     the instances that exist, with image id and health
##   ops/devstack.sh test <name> <suite..>  run suites against it: equiv, app-service, fuzz-api, abuse,
##                                          browser-service, fuzz-shiny, app (the R app tests)
##
## `name` is a short word ([a-z0-9-]); "dev" is the canonical instance (ops/test.sh dev-up) and is
## refused here so the two tools do not fight over it. Logs: $LOGDIR (default
## /scratch/nathan/R/T2-devdata/logs/<date-time>-<name>/).
set -eu
REPO=/scratch/nathan/R/T2
DEV=/scratch/nathan/R/T2-devdata
SVC=$REPO/T2Mobile/service
CHROME=/home/rstudio/R/T2-devdata/chrome/chrome-headless-shell-linux64/chrome-headless-shell
cmd=${1:-help}; name=${2:-}
case $cmd in up|down|test)
    [ -n "$name" ] || { echo "usage: devstack.sh $cmd <name> ..."; exit 1; }
    printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9-]{0,20}$' || { echo "name must be [a-z0-9-]"; exit 1; }
    [ "$name" != dev ] || { echo "'dev' is the canonical t2api-dev: use ops/test.sh dev-up"; exit 1; } ;;
esac
cont=t2api-$name; net=t2api-$name; img=t2api:$name
portfile=$DEV/devstack/$name.port
case $cmd in
up)
    port=${3:-}
    if [ -z "$port" ]; then                     # first free port from 3870 (3861 = t2api-dev, 3862 = dev website)
        port=3870; while ss -ltn 2>/dev/null | grep -q ":$port "; do port=$((port + 1)); done
    fi
    mkdir -p "$DEV/devstack" "$DEV/contact"
    echo "$port" > "$portfile"
    echo "building $img from $REPO (branch $(git -C "$REPO" rev-parse --abbrev-ref HEAD), $(git -C "$REPO" rev-parse --short=10 HEAD)$(git -C "$REPO" status --porcelain --untracked-files=no | grep -q . && echo ' + uncommitted changes'))"
    (cd "$SVC" && T2API_DEV_NAME=$cont T2API_DEV_PORT=$port T2API_DEV_NET=$net T2API_DEV_IMAGE=$img \
        docker compose -p "$cont" -f docker-compose.yml -f "$DEV/t2api-dev-contact.yml" up -d --build 2>&1 | tail -3)
    i=0; while [ $i -lt 30 ]; do
        if curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/healthz" | grep -q 200; then break; fi
        i=$((i + 1)); sleep 2
    done
    echo "$cont: http://127.0.0.1:$port  network $net  $(curl -s --max-time 5 "http://127.0.0.1:$port/v1/datasets" | grep -o '"name":"[^"]*"' | tr '\n' ' ')" ;;
down)
    (cd "$SVC" && T2API_DEV_NAME=$cont T2API_DEV_NET=$net T2API_DEV_IMAGE=$img \
        docker compose -p "$cont" -f docker-compose.yml -f "$DEV/t2api-dev-contact.yml" down 2>&1 | tail -2)
    rm -f "$portfile" ;;
ls)
    for c in $(docker ps -a --format '{{.Names}}' | grep -E '^t2api-[a-z0-9-]+$' | sort); do
        p=$(docker port "$c" 8080/tcp 2>/dev/null | head -1 | sed 's/.*://')
        h=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${p:-0}/healthz" 2>/dev/null || true)
        printf '%-16s %-22s port %-5s healthz %-4s %s\n' "$c" "$(docker inspect --format '{{.Config.Image}}' "$c")" "${p:-?}" "${h:-?}" "$(docker inspect --format '{{.State.Status}} since {{.State.StartedAt}}' "$c" | cut -c1-40)"
    done ;;
test)
    shift 2
    [ -f "$portfile" ] || { echo "no $portfile: is $cont up? (devstack.sh up $name)"; exit 1; }
    port=$(cat "$portfile")
    LOGDIR=${LOGDIR:-$DEV/logs/$(date +%Y%m%d-%H%M)-$name}; mkdir -p "$LOGDIR"
    say() { printf '\n== %s (%s) ==\n' "$1" "$cont"; }
    verdict() { grep -E "ALL PASS|FAILED|checks passed|FAIL|Error" "$1" | tail -${2:-3}; }
    rapi() {    # the rstudio image on this instance's network, like ops/test.sh rapi
        docker run --rm --network "$net" -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 -e NOT_CRAN=true \
            -e CHROMOTE_CHROME=$CHROME -e T2_API_URL=http://$cont:8080 -e T2_CONTACT_URL=http://$cont:8080/v1/contact \
            -e T2_DATASETS_DIR=/home/rstudio/R/T2-devdata/datasets --entrypoint Rscript rstudio:2026.03 "$@"
    }
    for s in "$@"; do case $s in
        equiv)       say equiv; (cd "$SVC" && T2API_NET=$net T2API_HOST=$cont T2API_PORT=$port T2_CODE=$REPO T2_DB=$DEV N_PROBES=${N_PROBES:-20} ./test.sh equiv) > "$LOGDIR/equiv.log" 2>&1; verdict "$LOGDIR/equiv.log" 1 ;;
        app-service) say app-service; (cd "$SVC" && T2API_NET=$net T2API_HOST=$cont T2API_PORT=$port T2_CODE=$REPO T2_DB=$DEV ./test.sh shiny) > "$LOGDIR/app-service.log" 2>&1; grep -E "ALL PASS|FAILED|^  FAIL" "$LOGDIR/app-service.log" | head ;;
        fuzz-api)    say fuzz-api; (cd "$SVC" && T2API_BASE=http://127.0.0.1:$port ./fuzz.sh) > "$LOGDIR/fuzz-api.log" 2>&1; tail -1 "$LOGDIR/fuzz-api.log" ;;
        abuse)       say abuse; (cd "$SVC" && T2API_NET=$net T2API_HOST=$cont T2API_PORT=$port T2_CODE=$REPO T2_DB=$DEV ./test.sh abuse) > "$LOGDIR/abuse.log" 2>&1; printf '%s PASS, %s FAIL\n' "$(grep -c PASS "$LOGDIR/abuse.log")" "$(grep -c FAIL "$LOGDIR/abuse.log")" ;;
        browser-service) say browser-service; d=$DEV/screenshots/shiny-$name; mkdir -m 777 -p "$d"; rm -f "${d:?}"/*
                     rapi test_browser_suite.R "/home/rstudio/R/T2-devdata/screenshots/shiny-$name" > "$LOGDIR/browser-service.log" 2>&1; verdict "$LOGDIR/browser-service.log" 1 ;;
        fuzz-shiny)  say fuzz-shiny; rapi test_shiny_fuzz.R > "$LOGDIR/fuzz-shiny.log" 2>&1; verdict "$LOGDIR/fuzz-shiny.log" 1 ;;
        app)         for t in test_app_sources.R test_app_thanos.R test_app_server.R test_app_survival.R test_t2_backend.R test_figure_export.R test_multidataset.R test_plot_style.R test_about_references.R; do
                         say "$t"; rapi $t > "$LOGDIR/${t%.R}.log" 2>&1; printf '%s PASS, ' "$(grep -c '^  PASS' "$LOGDIR/${t%.R}.log")"; grep -c "FAIL\|^Error" "$LOGDIR/${t%.R}.log" | sed 's/$/ FAIL+Error/'; done ;;
        *)           echo "unknown suite $s (equiv app-service fuzz-api abuse browser-service fuzz-shiny app)" ;;
    esac; done
    echo "log: $LOGDIR" ;;
*)  sed -n '2,19p' "$0" ;;
esac
