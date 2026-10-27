#!/bin/sh
## test.sh — the T2 test environment, one entry point. Every suite runs where it belongs
## (the R container, the T2T image on the dev service's network, a one-off Chrome container,
## the Go toolchain image, the Mac) and writes its log to $LOGDIR (default
## /scratch/nathan/R/T2-devdata/logs/<date-time>/). Nothing here touches production except
## the read-only `browser-live` check of the public site. Meant to be run by a Sonnet agent
## with one instruction ("ops/test.sh all, report the verdict lines and any FAIL").
##
##   ops/test.sh all                 everything below except ios (about 25 minutes)
##   ops/test.sh go                  the service's unit tests (go vet + go test)
##   ops/test.sh equiv               the service vs gitr(): values, presets, sources, menu (test_equivalence.R)
##   ops/test.sh app                 the headless app tests, in api mode against t2api-dev (rstudio image on the dev network)
##   ops/test.sh app-service         gitr over the service + the app tests, in the T2T image on the dev network
##   (browser-files is obsolete: the Shiny app is an api client only, DATASET-CONTRACT.md 2026-10-19; use browser-service)
##   ops/test.sh browser-service     the Chrome suite on the local code, over the dev service
##   ops/test.sh browser-live        the Chrome suite against https://www.fiveprime.org/T2/ (page reads only)
##   ops/test.sh browser-canary      the Chrome suite against shiny-t2t on 127.0.0.1:3857/T2T/
##   ops/test.sh fuzz                the API fuzzer, the abuse block, the Shiny input-channel fuzzer, the contact test
##   ops/test.sh swift               the T2Kit package tests on Linux
##   ops/test.sh ios [device]        the UI suite on the Mac simulator against the dev service (tunnel + sim_matrix)
##   ops/test.sh dev-up              (re)build and start the dev service t2api-dev on the dev data
##
## Environment: the dev service `t2api-dev` (T2Mobile/service/docker-compose.yml + the contact
## override) on http://127.0.0.1:3861 / network t2api-dev, reading /scratch/nathan/R/T2-devdata
## (README there: copies of the databases with the metadata keys, Chrome, screenshots, logs).
set -u
REPO=/scratch/nathan/R/T2
DEV=/scratch/nathan/R/T2-devdata
RCONT=r101101-rstudio-1
CHROME=/home/rstudio/R/T2-devdata/chrome/chrome-headless-shell-linux64/chrome-headless-shell
GOCACHE_DIR=${GOCACHE_DIR:-$DEV/gocache}
LOGDIR=${LOGDIR:-$DEV/logs/$(date +%Y%m%d-%H%M)}
mkdir -p "$LOGDIR" "$GOCACHE_DIR"
step=${1:-help}
say() { printf '\n== %s ==\n' "$1"; }
verdict() { grep -E "ALL PASS|FAILED|checks passed|FAIL|Error" "$1" | tail -${2:-3}; }
shots() { d=$DEV/screenshots/$1; mkdir -m 777 -p "$d"; rm -f "${d:?}"/*; echo "/home/rstudio/R/T2-devdata/screenshots/$1"; }
rapi() {    # rapi <script> [args]: an R test in api mode -- the rstudio image on the dev service's network, the
            # checkout mounted; T2_DATASETS_DIR gives the tests that need an oracle (test_gitr_api.R) the dev files.
            # Extra docker options go in $RAPI_OPTS (e.g. RAPI_OPTS="-e FOO=1").
    docker run --rm --network t2api-dev -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 -e NOT_CRAN=true \
        -e CHROMOTE_CHROME=$CHROME -e T2_API_URL=http://t2api-dev:8080 -e T2_CONTACT_URL=http://t2api-dev:8080/v1/contact \
        -e T2_DATASETS_DIR=/home/rstudio/R/T2-devdata/datasets ${RAPI_OPTS:-} --entrypoint Rscript rstudio:2026.03 "$@"
}
rtest() {   # rtest <script> [env...]: an R test in the R container, on the dev data (files; builders' tests only)
    s=$1; shift
    docker exec -w /home/rstudio/R/T2 -e NOT_CRAN=true -e T2_DATASETS_DIR=/home/rstudio/R/T2-devdata/datasets -e CHROMOTE_CHROME=$CHROME "$@" $RCONT Rscript "$s"
}
case $step in
go)      say go; (cd $REPO/T2Mobile/service && docker run --rm -v "$PWD":/src -w /src -v "$GOCACHE_DIR":/go/pkg/mod -e GOCACHE=/tmp/gocache golang:1.23-alpine sh -c 'go vet ./... && go test ./...') > "$LOGDIR/go.log" 2>&1; tail -2 "$LOGDIR/go.log" ;;
equiv)   say equiv; (cd $REPO/T2Mobile/service && T2API_NET=t2api-dev T2API_HOST=t2api-dev T2API_PORT=3861 T2_CODE=$REPO T2_DB=$DEV N_PROBES=${N_PROBES:-20} ./test.sh equiv) > "$LOGDIR/equiv.log" 2>&1; verdict "$LOGDIR/equiv.log" 1 ;;
app)     for t in test_app_sources.R test_app_thanos.R test_app_server.R test_app_survival.R test_t2_backend.R test_figure_export.R test_multidataset.R test_plot_style.R test_about_references.R test_contract_check.R test_app_analysis.R test_app_interactions.R; do
             say "$t"; rapi $t > "$LOGDIR/${t%.R}.log" 2>&1; printf '%s PASS, ' "$(grep -c '^  PASS' "$LOGDIR/${t%.R}.log")"; grep -c "FAIL\|^Error" "$LOGDIR/${t%.R}.log" | sed 's/$/ FAIL+Error/'; done ;;
app-service) say app-service; (cd $REPO/T2Mobile/service && T2API_NET=t2api-dev T2API_HOST=t2api-dev T2_CODE=$REPO T2_DB=$DEV ./test.sh shiny) > "$LOGDIR/app-service.log" 2>&1; grep -E "ALL PASS|FAILED|^  FAIL" "$LOGDIR/app-service.log" | head ;;
browser-files)   say browser-files; echo "obsolete: the Shiny app reads everything from the service (T2_API_URL); use browser-service" ;;
browser-service) say browser-service; d=$(shots shiny-service)
    docker run --rm --network t2api-dev -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 -e NOT_CRAN=true -e CHROMOTE_CHROME=$CHROME -e T2_API_URL=http://t2api-dev:8080 -e T2_CONTACT_URL=http://t2api-dev:8080/v1/contact --entrypoint Rscript rstudio:2026.03 test_browser_suite.R "$d" > "$LOGDIR/browser-service.log" 2>&1; verdict "$LOGDIR/browser-service.log" 1 ;;
browser-live)    say browser-live; d=$(shots shiny-live)
    docker run --rm --network shinypublic -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 -e NOT_CRAN=true -e CHROMOTE_CHROME=$CHROME -e T2_SITE_URL=https://www.fiveprime.org/T2/ ${T2_LIVE_CONTACT:+-e T2_CONTACT_URL=$T2_LIVE_CONTACT} --entrypoint Rscript rstudio:2026.03 test_browser_suite.R "$d" > "$LOGDIR/browser-live.log" 2>&1; verdict "$LOGDIR/browser-live.log" 1 ;;
browser-canary)  say browser-canary; d=$(shots shiny-canary)
    docker run --rm --network host -u rstudio -v /scratch/nathan/R:/home/rstudio/R -w /home/rstudio/R/T2 -e NOT_CRAN=true -e CHROMOTE_CHROME=$CHROME -e T2_SITE_URL=http://127.0.0.1:3857/T2T/ -e T2_CONTACT_URL=http://t2api:8080/v1/contact --entrypoint Rscript rstudio:2026.03 test_browser_suite.R "$d" > "$LOGDIR/browser-canary.log" 2>&1; verdict "$LOGDIR/browser-canary.log" 1 ;;
fuzz)    say fuzz-api; (cd $REPO/T2Mobile/service && T2API_BASE=http://127.0.0.1:3861 ./fuzz.sh) > "$LOGDIR/fuzz-api.log" 2>&1; tail -1 "$LOGDIR/fuzz-api.log"
         say abuse; (cd $REPO/T2Mobile/service && T2API_NET=t2api-dev T2API_HOST=t2api-dev T2API_PORT=3861 T2_CODE=$REPO T2_DB=$DEV ./test.sh abuse) > "$LOGDIR/abuse.log" 2>&1; printf '%s PASS, %s FAIL\n' "$(grep -c PASS "$LOGDIR/abuse.log")" "$(grep -c FAIL "$LOGDIR/abuse.log")"
         say fuzz-shiny; rapi test_shiny_fuzz.R > "$LOGDIR/fuzz-shiny.log" 2>&1; verdict "$LOGDIR/fuzz-shiny.log" 1
         say contact; (cd $REPO/T2Mobile/ops/contact && python3 contact_fuzz.py) > "$LOGDIR/contact.log" 2>&1; tail -1 "$LOGDIR/contact.log" ;;
swift)   say swift; (cd $REPO && docker run --rm -v "$PWD":/w -w /w/T2Mobile/ios/T2Kit swift:6.0-jammy swift test) > "$LOGDIR/swift.log" 2>&1; grep -E "Executed .* tests" "$LOGDIR/swift.log" | tail -1 ;;
ios)     say ios; dev=${2:-iPhone 18 Pro}   ## T2_MAC=<address> overrides the Mac (default: the MacBook Pro 10.1.0.9 on eno2, since 2026-10-22; the old MacBook was 10.0.0.110 / VPN 10.13.13.4)
         rsync -a --delete --exclude '.build/' --exclude 'Info.plist' --exclude 'build/' --exclude 'tools/' --exclude 'screenshots/' --exclude 'logs/' --exclude '*.xcodeproj' --exclude 'Local.xcconfig' $REPO/T2Mobile/ios/ nathan@${T2_MAC:-10.1.0.9}:Claude/T2Mobile/ios/
         scp -q $REPO/T2Mobile/ios/tools/sim_matrix.sh nathan@${T2_MAC:-10.1.0.9}:Claude/T2Mobile/ios/tools/ && ssh nathan@${T2_MAC:-10.1.0.9} 'chmod +x ~/Claude/T2Mobile/ios/tools/sim_matrix.sh'
         pgrep -f 'R 3861:127.0.0.1:3861' >/dev/null || ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -R 3861:127.0.0.1:3861 nathan@${T2_MAC:-10.1.0.9}
         ssh nathan@${T2_MAC:-10.1.0.9} "cd ~/Claude/T2Mobile && TEST_RUNNER_T2_SERVICE=http://127.0.0.1:3861 ./ios/tools/sim_matrix.sh \"$dev\":light" > "$LOGDIR/ios.log" 2>&1
         grep -E "passed:|FAILED:|Executed" "$LOGDIR/ios.log" | tail -4 ;;
dev-up)  say dev-up; (cd $REPO/T2Mobile/service && docker compose build && docker compose -f docker-compose.yml -f $DEV/t2api-dev-contact.yml up -d) 2>&1 | tail -2; sleep 20; curl -s http://127.0.0.1:3861/healthz ;;
## (browser-files is no longer in `all`: the app has no file mode)
all)     for s in go equiv app app-service browser-service fuzz swift; do "$0" "$s"; done; echo; echo "logs: $LOGDIR" ;;
*)       sed -n '2,22p' "$0" ;;
esac
echo "log: $LOGDIR"
