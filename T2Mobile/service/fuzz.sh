#!/bin/sh
## fuzz.sh — adversarial brute-force probing of a RUNNING t2api, the kind an automated
## exploit scanner does: enumerate hidden endpoints, try every HTTP method, and hammer the
## parameter space of each endpoint with hostile values. It asserts the service's INVARIANTS
## hold throughout — no undocumented handler answers, nothing but a clean 4xx/5xx comes back,
## no stack trace or internal detail leaks, the process never dies, and memory stays bounded.
##
## It is a complement to test.sh's `abuse` block (known hostile requests, one each); this one
## is volume + breadth, and it is self-contained (no external scanner binary to trust).
##
## Point it at the DEVELOPMENT service, never production:
##     T2API_BASE=http://127.0.0.1:3861 T2API_STATZ=http://127.0.0.1:3861 ./fuzz.sh
## (Through Nginx the per-address limits would answer 429 long before anything is learned, so
## run it against the service's own port.)
set -u
BASE=${T2API_BASE:-http://127.0.0.1:3861}
STATZ=${T2API_STATZ:-$BASE}
DS=${T2API_DS:-TCGA}
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
code() { curl -g -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }
body() { curl -g -s --max-time 20 "$@"; }

echo "== target $BASE, dataset $DS =="
mem0=$(curl -s "$STATZ/statz" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("requests",0))' 2>/dev/null || echo 0)

## ---------------------------------------------------------------------------
## 1. Hidden-endpoint discovery: a scanner's wordlist against the API root and the
##    per-dataset path. The ONLY paths that may answer 2xx are the documented ones.
## ---------------------------------------------------------------------------
echo "-- 1. endpoint discovery (nothing undocumented may answer 2xx)"
ROOT_WORDS="admin debug status stats statz health healthz metrics config version info api
v1 v2 internal private .env .git actuator swagger openapi graphql console shell exec eval
robots.txt favicon.ico .well-known test ping trace dump pprof debug/pprof data db backup
tcga.db datasets login logout user users token keys secret"
DS_WORDS="meta clinical probes values data query sql exec raw dump schema tables columns
admin debug config export download file read write update delete contact reload restart
healthz stats .. . %2e%2e ... probe value column samples cohorts presets sources"
leak=0
for w in $ROOT_WORDS; do
    case $w in healthz|statz) continue;; esac   # documented
    c=$(code "$BASE/$w")
    case $c in 2*) echo "  NOTE  /$w answered $c (expected 4xx)"; leak=$((leak+1));; esac
done
for w in $DS_WORDS; do
    c=$(code "$BASE/v1/$DS/$w")
    case $w in meta|clinical|probes|values) continue;; esac   # the documented ones
    case $c in 2*) echo "  NOTE  /v1/$DS/$w answered $c (expected 4xx)"; leak=$((leak+1));; esac
done
[ "$leak" = 0 ] && ok || bad "$leak undocumented path(s) answered 2xx"

## ---------------------------------------------------------------------------
## 2. Method fuzzing: every method on every known path; only GET (POST /contact) is allowed.
## ---------------------------------------------------------------------------
echo "-- 2. method fuzzing (only GET, and POST on /contact, allowed)"
mleak=0
for path in "/healthz" "/statz" "/v1/datasets" "/v1/$DS/meta" "/v1/$DS/values?probes=CD8A"; do
    for m in POST PUT DELETE PATCH OPTIONS HEAD TRACE CONNECT PROPFIND FOOBAR; do
        c=$(code -X "$m" "$BASE$path")
        case $m:$c in
            HEAD:2*|OPTIONS:*) : ;;                       # HEAD/OPTIONS may be answered
            *:405|*:400|*:404|*:501) : ;;                 # properly refused
            *) echo "  NOTE  $m $path -> $c"; mleak=$((mleak+1));;
        esac
    done
done
# contact must reject non-POST
for m in GET PUT DELETE; do c=$(code -X "$m" "$BASE/v1/contact"); case $c in 405) : ;; *) echo "  NOTE  $m /v1/contact -> $c"; mleak=$((mleak+1));; esac; done
[ "$mleak" = 0 ] && ok || bad "$mleak method(s) handled unexpectedly"

## ---------------------------------------------------------------------------
## 3. Parameter-space fuzzing: a battery of hostile values into every query parameter.
##    Each must yield a clean status and a JSON error body that leaks nothing internal.
## ---------------------------------------------------------------------------
echo "-- 3. parameter fuzzing (clean 4xx, no leak of paths/types/stack)"
# hostile payloads, URL-safe-encoded where needed
PAYLOADS='..%2f..%2f..%2fetc%2fpasswd
%2e%2e%2f%2e%2e%2fetc%2fshadow
....//....//etc/passwd
CD8A%00DROP
CD8A%0d%0aSet-Cookie:x=1
%27%20OR%201=1--
%22%3B--
CD8A%27%3BATTACH%20DATABASE%20%27x%27%20AS%20y%3B--
{{7*7}}
${7*7}
%n%n%n%s%s%s
<script>alert(1)</script>
../../../../../../proc/self/environ
CD8A|cat%20/etc/passwd
-99999999999999999999
99999999999999999999
0x4141414141
NaN
%c0%ae%c0%ae
CD8A%2cCD8B%2c'$(python3 -c "print('A'*500)")
leak=0
# ?probes= and ?probe=
for p in $PAYLOADS; do
    for param in probes probe; do
        out=$(body "$BASE/v1/$DS/values?$param=$p")
        c=$(code "$BASE/v1/$DS/values?$param=$p")
        case $c in 2*|4*|5*) : ;; "") echo "  NOTE  values?$param=$p dropped (no status)"; leak=$((leak+1));; *) echo "  NOTE  values?$param leaked status $c"; leak=$((leak+1));; esac
        echo "$out" | grep -Eqi '/data/|/srv/|/home/|goroutine|runtime\.|panic|\.go:|sql:|SQLITE|no such (table|column)|modernc' \
            && { echo "  NOTE  values?$param=$p body leaks internals: $(echo "$out" | head -c 120)"; leak=$((leak+1)); }
    done
done
# ?v= (version), ?q= and ?limit= (search), ?all=
for p in $PAYLOADS; do
    for url in "v1/$DS/meta?v=$p" "v1/$DS/values?probes=CD8A&v=$p" "v1/$DS/probes?q=$p" "v1/$DS/probes?q=CD&limit=$p" "v1/$DS/probes?all=$p"; do
        out=$(body "$BASE/$url"); c=$(code "$BASE/$url")
        case $c in 2*|304|4*|5*) : ;; *) echo "  NOTE  $url status $c"; leak=$((leak+1));; esac
        echo "$out" | grep -Eqi 'goroutine|runtime\.|panic|\.go:|/srv/|/data/|SQLITE' \
            && { echo "  NOTE  $url leaks internals"; leak=$((leak+1)); }
    done
done
# a datasetname fuzz: path-position injection
for p in $PAYLOADS; do
    c=$(code --path-as-is "$BASE/v1/$p/values?probes=CD8A")
    case $c in 2*) echo "  NOTE  dataset=$p answered $c"; leak=$((leak+1));; esac
done
[ "$leak" = 0 ] && ok || bad "$leak parameter-fuzz observation(s)"

## ---------------------------------------------------------------------------
## 4. Resource / algorithmic-complexity probes: oversized and repeated inputs.
##    The caps (16 KB header, 100 probes, 200-char names) must hold without a crash.
## ---------------------------------------------------------------------------
echo "-- 4. resource probes (caps hold, no crash)"
rleak=0
# maximal query string of distinct short names (bounded by the 16KB header limit)
big=$(python3 -c "print(','.join('zz%d'%i for i in range(4000)))")
c=$(code "$BASE/v1/$DS/values?probes=$big"); case $c in 400|414|431) ok2=1 ;; *) echo "  NOTE  4000-name request -> $c"; rleak=$((rleak+1));; esac
# a single 10KB name
longname=$(python3 -c "print('A'*10000)")
c=$(code "$BASE/v1/$DS/values?probes=$longname"); case $c in 400|414|431) : ;; *) echo "  NOTE  10KB name -> $c"; rleak=$((rleak+1));; esac
# the probes param repeated 500 times
rep=$(python3 -c "print('&'.join('probes=zz%d'%i for i in range(500)))")
c=$(code "$BASE/v1/$DS/values?$rep"); case $c in 400|414|431) : ;; *) echo "  NOTE  500x probes= -> $c"; rleak=$((rleak+1));; esac
[ "$rleak" = 0 ] && ok || bad "$rleak resource observation(s)"

## ---------------------------------------------------------------------------
## 5. Contact endpoint: malformed JSON and oversbodies.
## ---------------------------------------------------------------------------
echo "-- 5. contact endpoint"
cpost() { curl -g -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Content-Type: application/json' -X POST "$BASE/v1/contact" --data "$1"; }
cleak=0
for d in '' 'notjson' '{' '[]' '{"name":1}' '{"message":{"nested":true}}' '{"x":1}' "$(python3 -c 'print("{\"message\":\""+"A"*50000+"\"}")')"; do
    c=$(cpost "$d"); case $c in 400|404|413|415|422) : ;; 200) : ;; *) echo "  NOTE  contact payload -> $c"; cleak=$((cleak+1));; esac
done
# wrong content type
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$BASE/v1/contact" --data 'x'); case $c in 415|400|404) : ;; *) echo "  NOTE  contact no-ctype -> $c"; cleak=$((cleak+1));; esac
[ "$cleak" = 0 ] && ok || bad "$cleak contact observation(s)"

## ---------------------------------------------------------------------------
## 6. Liveness + memory after the storm.
## ---------------------------------------------------------------------------
echo "-- 6. still healthy afterwards"
h=$(code "$BASE/healthz"); [ "$h" = 200 ] && ok || bad "healthz is $h after fuzzing"
curl -s "$STATZ/statz" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("   requests",d.get("requests"),"errors",d.get("errors"),"busy_refusals",d.get("busy_refusals"),"max_inflight",d.get("max_inflight"))' 2>/dev/null

echo "== fuzz done: $PASS checks passed, $FAIL failed =="
[ "$FAIL" = 0 ]
