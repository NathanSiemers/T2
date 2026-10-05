#!/bin/sh
## Tests for the running t2api container (start it first: docker compose up -d --build).
##   ./test.sh            equivalence with gitr(), abuse checks, load test
##   ./test.sh load       load test only          ./test.sh equiv    equivalence only
## R is not installed on this host: the equivalence test runs in the T2T image, with the T2
## code and the same read-only databases, on the service's internal Docker network.
## By default it tests the PUBLISHED container (`t2api` on the `shinypublic` network,
## 127.0.0.1:3860). For the standalone development copy:
##   T2API_NET=t2api-dev T2API_HOST=t2api-dev T2API_PORT=3861 ./test.sh
## gitr() comes from the deployed T2T code; T2_CODE=/scratch/nathan/R/T2 uses the working copy,
## T2_DB=<dir with tcga.db and datasets/> other database files (default /scratch/shinyusb/T2).
cd "$(dirname "$0")"
what=${1:-all}
NET=${T2API_NET:-shinypublic}; HOST=${T2API_HOST:-t2api}; PORT=${T2API_PORT:-3860}
IMAGE=${T2API_IMAGE:-t2api:2026.10}
T2=/scratch/shinyusb
if [ "$what" = all ] || [ "$what" = equiv ]; then
    docker run --rm --network $NET -u 999:999 --read-only --tmpfs /tmp \
        -v ${T2_CODE:-$T2/T2T}:/srv/T2T:ro -v $T2/Thanos:/srv/Thanos:ro \
        -v ${T2_DB:-$T2/T2}/tcga.db:/srv/T2/tcga.db:ro -v ${T2_DB:-$T2/T2}/datasets:/srv/T2/datasets:ro \
        -v "$PWD/test_equivalence.R:/test_equivalence.R:ro" -w /srv/T2T -e T2_THANOS=/nonexistent \
        --entrypoint Rscript shinyt2t:2026.10 /test_equivalence.R http://$HOST:8080 ${N_PROBES:-60} 2>&1 |
        grep -v -E "rows returned|^Loading|tidyverse|^✔|^✖|^ℹ|Tk is not|Filter tab disabled|^──|^$"
fi
if [ "$what" = all ] || [ "$what" = abuse ]; then
    echo; echo "== malformed and hostile requests =="
    u=http://127.0.0.1:$PORT
    code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }
    chk() { [ "$2" = "$3" ] && echo "  PASS  $1 -> $2" || echo "  FAIL  $1 -> $2 (expected $3)"; }
    chk "unknown dataset"                 "$(code "$u/v1/nope/values?probes=CD8A")" 404
    chk "dataset path traversal"          "$(code --path-as-is "$u/v1/..%2f..%2fetc/values?probes=CD8A")" 404
    chk "no probes"                       "$(code "$u/v1/TCGA/values")" 400
    chk "51 probes in one request"        "$(code "$u/v1/TCGA/values?probes=$(seq -s, 1 51)")" 400
    chk "SQL in a probe name (just a name that does not exist)" "$(code "$u/v1/TCGA/values?probes=x%27%3B%20DROP%20TABLE%20probes%3B--")" 200
    chk "300-character probe name"        "$(code "$u/v1/TCGA/values?probes=$(head -c 300 /dev/zero | tr '\0' a)")" 400
    chk "POST is not allowed"             "$(code -X POST "$u/v1/TCGA/values?probes=CD8A")" 405
    chk "unknown path"                    "$(code "$u/v1/TCGA/../../data/tcga.db")" 404
    chk "still healthy afterwards"        "$(code "$u/healthz")" 200
    chk "probes table still there"        "$(code "$u/v1/TCGA/values?probes=CD8A")" 200
    etag=$(curl -s -D - -o /dev/null "$u/v1/TCGA/values?probes=CD8A" | tr -d '\r' | awk 'tolower($1)=="etag:" {print $2}')
    chk "conditional request is answered 304" "$(code -H "If-None-Match: $etag" "$u/v1/TCGA/values?probes=CD8A")" 304
fi
if [ "$what" = all ] || [ "$what" = load ]; then
    echo; echo "== load test (${CLIENTS:-200} concurrent clients) =="
    docker run --rm --network $NET --cpus 8 --memory 2g --entrypoint /loadtest $IMAGE \
        -url http://$HOST:8080 -dataset TCGA -c ${CLIENTS:-200} -d ${DURATION:-20s} -pool ${POOL:-2000} -hot ${HOT:-0.8}
    curl -s http://127.0.0.1:$PORT/statz; echo
    docker stats --no-stream --format 'service memory: {{.MemUsage}}' $HOST
fi
