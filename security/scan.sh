#!/usr/bin/env bash
# T2 security scan: repeatable audit of the T2 repository, the served checkouts, the Nginx and
# ShinyPublic stacks, the running containers and the host persistence points.
# Threat model: code or configuration written by an AI coding session (or anyone) that opens a
# backdoor. Nothing is trusted because it is documented; every check looks at what is there NOW.
#
#   security/scan.sh              run every check (needs docker; the Go rebuild needs the network)
#   security/scan.sh --quick      skip the Go rebuild (the live binary is compared with the
#                                 hash recorded by the last full run in baseline/)
#   security/scan.sh --baseline   (re)write baseline/ from the CURRENT state after you have reviewed
#                                 it; run it only after a human accepted the change
#   security/scan.sh --raw        print the unfiltered hits of the pattern detectors (to review
#                                 or extend an allowlist)
#
# Output: one PASS / FAIL / WARN line per check, a count, exit status 1 on any FAIL.
# Read-only: writes only to baseline/ (with --baseline) and a mktemp directory.  No sudo.
# See README.md.
set -u
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${T2SEC_REPO:-$(cd "$HERE/.." && pwd)}
PUB=${T2SEC_PUB:-/scratch/Docker/ShinyPublic}
NGX=${T2SEC_NGX:-/scratch/Docker/Nginx}
SERVED=${T2SEC_SERVED:-/scratch/shinyusb/T2T}
THANOS=${T2SEC_THANOS:-/scratch/shinyusb/Thanos}
AL=$HERE/allowlist
BL=$HERE/baseline
QUICK=0; WRITEBL=0; RAW=0
for a in "$@"; do case $a in --quick) QUICK=1;; --baseline) WRITEBL=1;; --raw) RAW=1;;
  -h|--help) sed -n '2,19p' "$0"; exit 0;; *) echo "unknown option $a" >&2; exit 2;; esac; done
TMP=$(mktemp -d "${TMPDIR:-/tmp}/t2sec.XXXXXX"); trap 'rm -rf "$TMP" 2>/dev/null' EXIT
[ $WRITEBL = 1 ] && mkdir -p "$BL"

# counters live in files, because checks run inside pipelines (subshells)
: > "$TMP/n.p"; : > "$TMP/n.f"; : > "$TMP/n.w"
pass() { printf 'PASS  %s\n' "$1"; echo . >> "$TMP/n.p"; }
fail() { printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -${LINES_SHOWN:-12} | sed 's/^/        /'; echo . >> "$TMP/n.f"; }
warn() { printf 'WARN  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -${LINES_SHOWN:-12} | sed 's/^/        /'; echo . >> "$TMP/n.w"; }
have() { command -v "$1" >/dev/null 2>&1; }
DOCKER_OK=0; have docker && docker info >/dev/null 2>&1 && DOCKER_OK=1
sha() { sha256sum "$@" 2>/dev/null; }

# allowlist file -> patterns (comment and blank lines removed)
al_clean() { [ -f "$1" ] && grep -vE '^[[:space:]]*(#|$)' "$1" > "$2" || : > "$2"; }
# al_anchor <allowlist> <out> : same, but every entry is anchored at the START of the record, so that an entry
# `path:[0-9]+:content` can only match a record that begins with that repo-relative path (a comment, a file name
# or padding inside the code cannot imitate it). Entries are grouped, so a top-level `a|b` stays two alternatives.
al_anchor() { al_clean "$1" "$2.raw"; sed 's/^/^(/; s/$/)/' "$2.raw" > "$2"; }
# relpath : stdin = grep records (abs path first) -> repo-relative path (REPO/ stripped; PUB/, NGX/ and ~/ for the
# other roots), applied BEFORE allowlist matching. Records are never truncated before matching.
relpath() { sed "s#^$REPO/##; s#^$PUB/#PUB/#; s#^$NGX/#NGX/#; s#^$HOME/#~/#"; }

# bl_check <name> <description>  : stdin = current state (text); compares with baseline/<name>
bl_check() {
  local name=$1 desc=$2 cur="$TMP/cur.$1"; cat > "$cur"
  if [ $WRITEBL = 1 ]; then cp "$cur" "$BL/$name"; pass "baseline written: $desc ($name, $(wc -l < "$cur") lines)"; return; fi
  if [ ! -f "$BL/$name" ]; then warn "$desc: no baseline/$name (run scan.sh --baseline after review)"; return; fi
  if diff -q "$BL/$name" "$cur" >/dev/null; then pass "$desc unchanged"
  else ${BLLEVEL:-fail} "$desc CHANGED since the reviewed baseline (diff: - baseline, + now)" "$(diff "$BL/$name" "$cur" | grep '^[<>]' | sed 's/^</-/;s/^>/+/')"; fi
}

# detector <name> <pattern-ERE> <allowlist-basename> : stdin = NUL-separated absolute file list
detector() {
  local name=$1 pat=$2 alf=$3 hits="$TMP/hits.$1" a="$TMP/al.$1"
  tr '\n' '\0' | xargs -0 -r grep -HInE -- "$pat" 2>/dev/null | relpath > "$hits"
  if [ $RAW = 1 ]; then echo "---- raw hits: $name ($(wc -l < "$hits"))"; cut -c1-260 "$hits"; return; fi
  al_anchor "$AL/$alf" "$a"
  local rest; rest=$(grep -vEf "$a" "$hits" | cut -c1-260)
  local n; n=$(wc -l < "$hits"); local k; k=$(grep -cEf "$a" "$hits")
  if [ -z "$rest" ]; then pass "$name: no unlisted hit ($k allowlisted of $n)"
  else fail "$name: $(printf '%s\n' "$rest" | wc -l) hit(s) not on allowlist/$alf" "$rest"; fi
}

repo_files() { (cd "$REPO" && git ls-files -co --exclude-standard -z | tr '\0' '\n' | grep -v '^\.claude/worktrees/\|^security/' | sed "s#^#$REPO/#"); }

echo "T2 security scan  $(date '+%F %T')  repo=$REPO  head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
[ $DOCKER_OK = 0 ] && warn "docker not usable: container, image and Go rebuild checks are skipped"

###############################################################################################
echo "== 1. configuration and script integrity (sha256 manifests against baseline/) =="
manifest() {   # list of files (globs expanded by the caller) -> "sha  path" lines, paths relative-ized
  for f in "$@"; do if [ -f "$f" ]; then sha256sum "$f" | sed "s#  $REPO/#  REPO/#; s#  $HOME/#  ~/#"; else echo "MISSING  ${f/#$HOME/\~}"; fi; done
}
{ manifest "$NGX"/nginx.conf "$NGX"/default.conf "$NGX"/Dockerfile "$NGX"/docker-compose.yml
  find "$NGX/html" -type f -not -path '*/2023*' | sort | while read -r f; do sha256sum "$f"; done
} | bl_check m-nginx "Nginx stack (nginx.conf, default.conf, Dockerfile, compose, html/)"
manifest "$PUB"/docker-compose.yml "$PUB"/Dockerfile "$PUB"/entrypoint.sh "$PUB"/host-setup.sh "$PUB"/t2t/Dockerfile \
  "$PUB"/t2t/pool-entrypoint.sh "$PUB"/haproxy/haproxy.cfg "$PUB"/conf/*.conf "$PUB"/conf/*Renviron* \
  "$PUB"/scripts/*.sh | bl_check m-shinypublic "ShinyPublic stack (compose, Dockerfiles, entrypoints, haproxy, conf, scripts)"
manifest "$HOME"/bin/t2-contact-mail.sh "$HOME"/bin/t2-contact-mail.py "$HOME"/.bashrc "$HOME"/.profile \
  "$HOME"/.claude/settings.json "$REPO"/.claude/settings.local.json | bl_check m-host "host files (~/bin/t2-contact-mail.*, shell rc files, Claude permission files)"
manifest "$REPO"/T2Mobile/ops/deploy.sh "$REPO"/T2Mobile/ops/test.sh "$REPO"/T2Mobile/ops/allow-deploy.py "$REPO"/T2Mobile/ops/contact/* \
  "$REPO"/T2Mobile/service/Dockerfile "$REPO"/T2Mobile/service/docker-compose.yml "$REPO"/T2Mobile/standby/docker-compose.yml \
  "$REPO"/T2Mobile/service/go.mod "$REPO"/T2Mobile/service/go.sum "$REPO"/T2Mobile/ios/testflight.sh "$REPO"/T2Mobile/ios/mac_setup.sh \
  "$REPO"/T2Mobile/ios/tools/* "$REPO"/T2Mobile/ios/T2App/project.yml "$REPO"/T2Mobile/ios/T2App/Config/T2.xcconfig \
  "$REPO"/.github/workflows/* "$REPO"/.gitignore "$REPO"/.gitattributes | bl_check m-repo-ops "repo ops, build and release files (deploy.sh, test.sh, Dockerfile, go.mod/sum, iOS tooling, CI)"
( cd "$HERE" && sha256sum scan.sh allowlist/*.txt README.md 2>/dev/null ) | bl_check m-security "the suite itself (scan.sh, allowlist/*.txt): a weakened scan or a widened allowlist is a change to review"
cmp -s "$HOME/bin/t2-contact-mail.sh" "$REPO/T2Mobile/ops/contact/t2-contact-mail.sh" && cmp -s "$HOME/bin/t2-contact-mail.py" "$REPO/T2Mobile/ops/contact/t2-contact-mail.py" \
  && pass "~/bin/t2-contact-mail.{sh,py} identical to the reviewed copies in T2Mobile/ops/contact" \
  || fail "~/bin/t2-contact-mail.{sh,py} differ from T2Mobile/ops/contact (the mail script is what cron runs every 15 min)"
for f in "$PUB/haproxy/cookie.env" "$HOME/.appstoreconnect/t2-testflight.env" "$REPO/github.token"; do
  [ -e "$f" ] && { m=$(stat -c %a "$f"); case $m in 600|400) :;; *) fail "secret file mode: ${f/#$HOME/\~} is $m (want 600)";; esac; }
done

###############################################################################################
echo "== 2. served code versus the repository =="
if [ -d "$SERVED/.git" ]; then
  sh_=$(git -C "$SERVED" rev-parse HEAD); main=$(git -C "$REPO" rev-parse main)
  st=$(git -C "$SERVED" status --porcelain --ignored 2>/dev/null)
  al_clean "$AL/served-untracked.txt" "$TMP/al.served"
  rest=$(printf '%s\n' "$st" | grep -v '^$' | grep -vEf "$TMP/al.served")
  [ -z "$rest" ] && pass "served checkout $SERVED: no modified, untracked or ignored file beyond the allowlist" \
    || fail "served checkout $SERVED has local changes or unknown files" "$rest"
  if git -C "$REPO" merge-base --is-ancestor "$sh_" "$main" 2>/dev/null; then
    [ "$sh_" = "$main" ] && pass "served checkout is at the repository's main ($(echo $sh_ | cut -c1-7))" \
      || { d=$(git -C "$REPO" diff --name-only "$sh_" "$main" | grep -vE '\.md$|^T2Mobile/(ops|docs|NOTES)|^\.github' ); \
           if [ -z "$d" ]; then pass "served checkout $(echo $sh_|cut -c1-7) is behind main by commits that touch no served code (docs/ops only)"; \
           else warn "served checkout $(echo $sh_|cut -c1-7) is behind main; code changed since:" "$d"; fi; }
  else fail "served HEAD $(echo $sh_|cut -c1-7) is NOT an ancestor of the repository's main (served code that was never on main)"; fi
  # the served tree must equal its own HEAD byte for byte (already covered by status), and the objects must be sound
  git -C "$SERVED" fsck --connectivity-only >/dev/null 2>&1 && pass "served checkout object store is consistent" || warn "served checkout: git fsck complained"
else warn "served checkout $SERVED not found"; fi
if [ -d "$THANOS/.git" ]; then
  st=$(git -C "$THANOS" status --porcelain --ignored 2>/dev/null)
  [ -z "$st" ] && pass "Thanos $THANOS: clean, no untracked or ignored files" || fail "Thanos has local changes or untracked files" "$st"
  h=$(git -C "$THANOS" rev-parse HEAD); o=$(git -C "$THANOS" rev-parse origin/main 2>/dev/null)
  [ "$h" = "$o" ] && pass "Thanos HEAD equals its origin/main ($(echo $h|cut -c1-7))" || warn "Thanos HEAD ($(echo $h|cut -c1-7)) differs from its local origin/main ($(echo $o|cut -c1-7))"
else warn "Thanos $THANOS not found"; fi
git -C "$THANOS" rev-parse HEAD 2>/dev/null | bl_check thanos-head "Thanos HEAD commit (sourced into every user session)"

###############################################################################################
echo "== 3. running containers and images =="
PROD='^(nginx-nginx-1|t2api|t2api-web|t2api-dev|shiny-t2t|shiny-t2-dev|shinypublic-shiny-t2tc-[0-9]+|haproxy-t2tc|shiny-allnets|shiny-pc3|shiny-scmel|shiny-scblood|shiny-genio|shiny|openwebui)$'
if [ $DOCKER_OK = 1 ]; then
  names=$(docker ps --format '{{.Names}}' | grep -E "$PROD" | sort)
  other=$(docker ps --format '{{.Names}} {{.Image}}' | awk -v re="$PROD" '$1 !~ re && $2 !~ /^rstudio:/')
  [ -z "$other" ] && pass "no running container outside the known production/dev set" || warn "running container(s) not in the known set (new, or a transient test?)" "$other"
  for c in $names; do
    docker inspect "$c" --format '{{.Name}} image={{.Image}} cfgimage={{.Config.Image}} priv={{.HostConfig.Privileged}} net={{.HostConfig.NetworkMode}} capadd={{.HostConfig.CapAdd}} dns={{.HostConfig.Dns}} extrahosts={{.HostConfig.ExtraHosts}} pid={{.HostConfig.PidMode}} user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} ep={{.Config.Entrypoint}} cmd={{.Config.Cmd}}'
    docker inspect "$c" --format '{{range .Mounts}}   mount {{.Type}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' | grep . | sort
    docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed 's/=.*//' | sort | sed "s#^#   envname #"
  done | sed 's#^/##' | sed -E '/^(t2api-dev|shiny-t2-dev) /s/image=sha256:[0-9a-f]+/image=<dev image: rebuilt by test.sh dev-up>/' | bl_check containers "running containers: image id, privileges, network, entrypoint, mounts, env NAMES"
  # privilege lint (independent of the baseline)
  bad=$(for c in $names; do
    docker inspect "$c" --format '{{.Name}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.CapAdd}}|{{.HostConfig.PidMode}}|{{.HostConfig.Devices}}|{{range .Mounts}}{{.Source}} {{end}}' | sed 's#^/##' |
      awk -F'|' '{n=$1; if($2=="true")print n" privileged"; if($3=="host")print n" network=host"; if($4!="[]"&&$4!="<no value>"&&$4!="")print n" cap_add="$4; if($5=="host")print n" pid=host"; if($6!="[]"&&$6!="")print n" devices="$6; if($7 ~ /docker\.sock/)print n" mounts docker.sock"; if($7 ~ /(^| )\/( |$)/)print n" mounts /" }'
    done | sort -u)
  al_clean "$AL/docker-runtime.txt" "$TMP/al.drt"
  rest=$(printf '%s\n' "$bad" | grep -v '^$' | grep -vEf "$TMP/al.drt")
  [ -z "$rest" ] && pass "container privilege lint (privileged, host net/pid, cap_add, devices, docker.sock, / mount): clean beyond the allowlist" || fail "container privilege lint" "$rest"
  # docker diff: only runtime files may differ from the image
  al_clean "$AL/docker-diff.txt" "$TMP/al.dd"
  dd=$(for c in $(echo "$names" | grep -vx openwebui); do docker diff "$c" 2>/dev/null | sed "s#^#$c #"; done | grep -vEf "$TMP/al.dd")
  [ -z "$dd" ] && pass "docker diff of every production container shows only runtime files (allowlist/docker-diff.txt)" || fail "docker diff: files changed in a container that are not runtime files" "$dd"
  # nginx: the config in the running container is the file on disk
  for p in nginx.conf default.conf; do
    a=$(docker exec nginx-nginx-1 sha256sum /etc/nginx/conf.d/$p 2>/dev/null | cut -d' ' -f1); b=$(sha256sum "$NGX/$p" 2>/dev/null | cut -d' ' -f1)
    [ -n "$a" ] && [ "$a" = "$b" ] && pass "nginx: conf.d/$p in the container equals $NGX/$p" || fail "nginx: conf.d/$p in the container differs from $NGX/$p (container $a, file $b)"
  done
  docker exec nginx-nginx-1 sha256sum /etc/nginx/nginx.conf 2>/dev/null | cut -d' ' -f1 | bl_check nginx-toplevel "nginx: the container's top-level /etc/nginx/nginx.conf"
  # Rprofile / Renviron inside the Shiny images (code R runs at every start)
  for img in shinyt2t:2026.10 shinypublic:2026.10; do
    for f in Rprofile.site Renviron.site; do
      printf '%s %s ' "$img" "$f"; docker run --rm --entrypoint cat "$img" /usr/local/lib/R/etc/$f 2>/dev/null | sha256sum | cut -d' ' -f1
    done; done | bl_check r-site "R site profile/environment files inside the Shiny images (executed at every R start)"
  # layer history of the production images: the commands that built them
  for img in t2api:2026.10 shinyt2t:2026.10 shinypublic:2026.10 nginx-nginx:latest; do
    docker history --no-trunc --format '{{.CreatedBy}}' "$img" 2>/dev/null | sed -E 's/sha256:[0-9a-f]{64}/sha256:<id>/g; s/file:[0-9a-f]{64}/file:<id>/g' | sed "s#^#$img #"
  done | bl_check image-history "image build history (docker history) of the production images"
else warn "containers/images/nginx-in-container/image-history: skipped (no docker)"; fi

###############################################################################################
echo "== 4. Go service: routes, dependencies, binary =="
SVC=$REPO/T2Mobile/service
grep -hoE 'HandleFunc\("[^"]+"|Handle\("[^"]+"' "$SVC"/cmd/t2api/*.go 2>/dev/null | grep -v _test | sort | bl_check go-routes "t2api mux routes"
# every route must be in the documented contract
undoc=$(grep -hoE 'HandleFunc\("[A-Z]+ [^"]+"' "$SVC"/cmd/t2api/main.go | sed -E 's/HandleFunc\("[A-Z]+ //; s/"$//; s#\{ds\}#{ds}#' | while read -r r; do
  grep -qF -- "$(echo "$r" | sed 's#/{ds}/#/{ds}/#')" "$REPO/T2Mobile/docs/API.md" || echo "$r"; done)
[ -z "$undoc" ] && pass "every mux route is documented in T2Mobile/docs/API.md" || fail "mux route(s) not in docs/API.md" "$undoc"
awk '/^require \(/{f=1;next} /^\)/{f=0} f||/^require /{print}' "$SVC/go.mod" | sed 's/^require //' | bl_check go-deps "Go dependencies (go.mod require)"
# go.mod: no replace / exclude / retract directive at all (a replace would swap the code behind an allowlisted module path)
gm="$SVC/go.mod"
dirs=$(grep -nE '^[[:space:]]*(replace|exclude|retract)\b' "$gm" 2>/dev/null)
[ -z "$dirs" ] && pass "go.mod: no replace, exclude or retract directive" || fail "go.mod contains replace/exclude/retract (the module path in a require line may not be the code that is built)" "$dirs"
# module paths named in require lines / require ( ... ) blocks only, each must be on allowlist/go-deps.txt (whole line, fixed string)
al_clean "$AL/go-deps.txt" "$TMP/al.godeps"
reqmods=$(sed 's#//.*$##' "$gm" 2>/dev/null | awk '/^[[:space:]]*require[[:space:]]*\(/{f=1;next} f&&/^[[:space:]]*\)/{f=0;next} f{print $1;next} /^[[:space:]]*require[[:space:]]+/{print $2}')
extra=$(printf '%s\n' "$reqmods" | grep -v '^$' | grep -vxFf "$TMP/al.godeps")
nreq=$(printf '%s\n' "$reqmods" | grep -vc '^$')
[ -z "$extra" ] && [ "$nreq" -gt 0 ] && pass "all $nreq Go dependencies in go.mod are on allowlist/go-deps.txt (modernc.org/sqlite and its known transitive set)" || fail "unexpected Go dependency (not on allowlist/go-deps.txt), or no require found ($nreq)" "$extra"
# detectors over the Go sources
{ find "$SVC" -name '*.go' -not -path '*/vendor/*'; } | detector go-detector \
 '"os/exec"|exec\.Command|net\.Dial|net\.Listen|net\.Lookup|http\.(Get|Post|Head|PostForm|NewRequest|DefaultClient|Client)|\bunsafe\b|"syscall"|^func init\(|go:linkname|go:embed|import "C"|os\.Getenv|os\.Environ|os\.(WriteFile|Create|OpenFile|Remove|Rename|Mkdir|Symlink|Chmod)|ioutil|plugin\.Open|ListenAndServe|Header\.Get|Header\.Values|URL\.Query\(\)|FormValue|Cookie|RemoteAddr|\.Exec\(|ATTACH|reflect\.Value|runtime\.SetFinalizer|os\.Exit|"crypto/tls"|InsecureSkipVerify|r\.(URL|Header|PathValue)[^;]*(==|!=) *"' go.txt
LIVE1=""; if [ $DOCKER_OK = 1 ]; then
  docker cp t2api:/t2api "$TMP/t2api-live" >/dev/null 2>&1; docker cp t2api-web:/t2api "$TMP/t2api-web-live" >/dev/null 2>&1
  a=$(sha256sum "$TMP/t2api-live" 2>/dev/null | cut -d' ' -f1); b=$(sha256sum "$TMP/t2api-web-live" 2>/dev/null | cut -d' ' -f1)
  [ -n "$a" ] && [ "$a" = "$b" ] && pass "t2api and t2api-web run the same binary ($(echo $a|cut -c1-12))" || fail "t2api and t2api-web binaries differ or missing ($a / $b)"
  LIVE1=$a
  if [ $QUICK = 1 ]; then
    if [ -f "$BL/go-binary.sha256" ]; then [ "$(cat "$BL/go-binary.sha256")" = "$a" ] && pass "live t2api binary equals the hash proven by the last full rebuild (--quick: no rebuild now)" || fail "live t2api binary ($a) differs from the last proven rebuild hash; run without --quick"
    else warn "--quick: no baseline/go-binary.sha256 to compare the live binary with"; fi
  else
    GOUT="$TMP/go"; mkdir -p "$GOUT/src" "$GOUT/pkg" "$GOUT/out"; git -C "$REPO" archive HEAD T2Mobile/service | tar -x -C "$GOUT"; mv "$GOUT/T2Mobile/service/"* "$GOUT/src/"
    [ -n "$(git -C "$REPO" status --porcelain -- T2Mobile/service | grep -v '^??')$(git -C "$REPO" status --porcelain -- T2Mobile/service/cmd | grep '^??')" ] && warn "uncommitted changes under T2Mobile/service (the rebuild uses the COMMITTED tree, git HEAD; review the working-tree changes separately)" "$(git -C "$REPO" status --porcelain -- T2Mobile/service | head -6)"
    if timeout 900 docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e GOCACHE=/tmp/gocache -e GOPATH=/gp -e GOFLAGS=-mod=readonly -v "$GOUT/src":/src:ro -v "$GOUT/pkg":/gp -v "$GOUT/out":/out -w /src golang:1.23-alpine \
         sh -c 'go mod download 2>&1 | tail -2; go mod verify && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/t2api ./cmd/t2api' > "$GOUT/log" 2>&1; then
      r=$(sha256sum "$GOUT/out/t2api" | cut -d' ' -f1)
      grep -q 'all modules verified' "$GOUT/log" && pass "go mod verify: all modules match go.sum" || warn "go mod verify did not report 'all modules verified'" "$(tail -3 "$GOUT/log")"
      if [ "$r" = "$a" ]; then pass "t2api rebuilt from the committed source (git HEAD) is byte-identical to the live binary ($(echo $r|cut -c1-12))"; [ $WRITEBL = 1 ] && echo "$r" > "$BL/go-binary.sha256"
      else fail "rebuilt t2api ($r) != live binary ($a): the binary in production was not built from this source (or the Go toolchain image changed)"; fi
    else warn "Go rebuild could not run (needs docker, image golang:1.23-alpine and network for modules)" "$(tail -3 "$GOUT/log" 2>/dev/null)"; fi
  fi
else warn "Go binary checks skipped (no docker)"; fi

###############################################################################################
echo "== 5. Nginx semantics (nginx.conf and default.conf as on disk) =="
NG=$NGX/nginx.conf; NGD=$NGX/default.conf
ng_code() { grep -hvE '^[[:space:]]*#' "$NG" "$NGD" | sed -E 's/[[:space:]]#.*$//'; }
forb=$(ng_code | grep -nE '\b(mirror|post_action|sub_filter|js_import|js_content|js_set|js_var|njs|lua_|content_by_lua|access_by_lua|perl_|auth_request|autoindex|alias|stream|fastcgi_pass|uwsgi_pass|scgi_pass|grpc_pass|ssi|dav_methods|proxy_redirect|add_trailing_slash|more_set_headers|set_real_ip_from|real_ip_header)\b')
[ -z "$forb" ] && pass "nginx: no mirror/post_action/sub_filter/js/lua/perl/auth_request/autoindex/alias/stream/real_ip directive" || fail "nginx: forbidden directive" "$forb"
pp=$(ng_code | grep -oE 'proxy_pass +[^;]+' | sort -u)
al_clean "$AL/nginx-proxy-pass.txt" "$TMP/al.pp"
rest=$(printf '%s\n' "$pp" | grep -vEf "$TMP/al.pp" | grep -v '^$')
[ -z "$rest" ] && pass "nginx: every proxy_pass target is a known container/upstream" || fail "nginx: unknown proxy_pass target" "$rest"
apps=$(ng_code | grep -oE 'set +\$app +[^;]+' | sort -u)
rest=$(printf '%s\n' "$apps" | grep -vE '^set +\$app +(haproxy-t2tc|shiny-allnets|shiny-pc3|shiny-scmel|shiny-scblood|shiny-genio)$' | grep -v '^$')
[ -z "$rest" ] && pass "nginx: \$app names are only the known containers" || fail "nginx: unknown \$app target" "$rest"
srv=$(ng_code | grep -oE '^[[:space:]]*server +[^;]+;' | grep -vE 'server_name|server +t2api:8080 resolve;' )
[ -z "$srv" ] && pass "nginx: the only upstream server is t2api:8080" || fail "nginx: unexpected upstream server line" "$srv"
rt=$(ng_code | grep -oE '(^|[;{ ])return +[^;]+;' | sed -E 's/^[;{ ]+//' | sort -u | grep -vE '^return (301 (https://\$host\$request_uri|/[A-Za-z0-9]*/?)|404|444);$')
[ -z "$rt" ] && pass "nginx: every return is a relative redirect, 404 or 444 (no external URL)" || fail "nginx: return with an unexpected target" "$rt"
rw=$(ng_code | grep -oE 'rewrite +[^;]+;' | sort -u | grep -vE '^rewrite (\^ /healthz break|\^/api/t2/\(\.\*\)\$ /\$1 break|\^/T2/\(\.\*\)\$ /T2Tc/\$1 break|\^/T2T/\(\.\*\)\$ +/T2/\$1 permanent|\^/T2Tc/\(\.\*\)\$ +/T2/\$1 permanent);$')
[ -z "$rw" ] && pass "nginx: rewrites are only the documented ones" || fail "nginx: unexpected rewrite" "$rw"
lg=$(ng_code | grep -oE '(access_log|error_log) +[^;]+' | sort -u | sed -E 's/ main if=\$t2api_failed//' | grep -vE '^(access_log|error_log) +(/var/log/nginx/access\.log|/var/log/fiveprime\.ssl\.log)$')
[ -z "$lg" ] && pass "nginx: log targets are the two known files" || fail "nginx: unexpected log target" "$lg"
inc=$(ng_code | grep -oE 'include +[^;]+' | sort -u | grep -vE '^include +(/etc/nginx/mime\.types|/etc/nginx/conf\.d/\*\.conf)$')
[ -z "$inc" ] && pass "nginx: includes are only mime.types and conf.d/*.conf" || fail "nginx: unexpected include" "$inc"
ifs=$(ng_code | grep -E '\bif *\(' | sed 's/^[[:space:]]*//' | sort -u | grep -vE '^if \(\$allowed_site = 0\) \{ return 444; \}$')
[ -z "$ifs" ] && pass "nginx: the only if-block is the host allow check" || fail "nginx: unexpected if-block" "$ifs"
ah=$(ng_code | grep -oE 'add_header +[^;]+' | sort -u | grep -vE '^add_header +(Strict-Transport-Security|X-Content-Type-Options|X-Frame-Options|Referrer-Policy) +"[^"<>]*" +always$')
[ -z "$ah" ] && pass "nginx: add_header only sets the four security headers" || fail "nginx: unexpected add_header" "$ah"
loc=$(ng_code | grep -oE 'location +[^{]+\{' | sed 's/ *{$//' | sort -u)
echo "$loc" | bl_check nginx-locations "nginx location blocks (what is exposed)"

###############################################################################################
echo "== 6. compose files and Dockerfiles =="
cf=("$NGX/docker-compose.yml" "$PUB/docker-compose.yml" "$SVC/docker-compose.yml" "$REPO/T2Mobile/standby/docker-compose.yml")
for f in "${cf[@]}"; do [ -f "$f" ] && echo "$f"; done | tr '\n' '\0' | detector compose-lint \
 '^[^#]*(privileged|docker\.sock|network_mode|cap_add|extra_hosts|[^_]dns:|pid:|ipc:|devices:|userns_mode|sysctls|apparmor|seccomp|unconfined|ports: *\["?0\.0\.0\.0|- "?/:/|/etc:|/root|/proc|/sys:|image: *[a-z]+/)' compose.txt
mt=$(for f in "$PUB/docker-compose.yml" "$NGX/docker-compose.yml"; do grep -vE '^[[:space:]]*#' "$f" | grep -E '^[[:space:]]+- +["]?(/|\./)[^ ]*:/' | sed -E 's/^[[:space:]]+- +//; s/#.*//; s/[[:space:]]+$//' ; done | sort -u)
echo "$mt" | bl_check compose-mounts "compose bind mounts (host path:container path[:mode])"
ex=$(for f in "$PUB/docker-compose.yml" "$NGX/docker-compose.yml"; do grep -vE '^[[:space:]]*#' "$f" | grep -E '^[[:space:]]+(image|entrypoint|command):' | sed -E 's/#.*//'; done | sort -u)
echo "$ex" | bl_check compose-images "compose image/entrypoint/command lines"
{ ls "$PUB"/Dockerfile "$PUB"/t2t/Dockerfile "$NGX"/Dockerfile "$SVC"/Dockerfile 2>/dev/null; } | tr '\n' '\0' | detector dockerfile-lint \
 '^[[:space:]]*(ADD +https?:|RUN.*(curl|wget)|RUN.*\|[[:space:]]*(ba)?sh|RUN.*(git clone|pip install|npm install|apt-get install|apt install)|USER +root|ENV.*(KEY|TOKEN|PASS|SECRET)|COPY +--from=[^b])' dockerfile.txt

###############################################################################################
echo "== 7. outbound hosts, executable-content patterns, secrets, hidden characters =="
# code-like files of the repo (plus the Docker stacks' scripts and the host mail script)
codefiles() { repo_files | grep -E '\.(R|r|Rmd|go|swift|sh|py|yml|yaml|plist|xcconfig|conf|cfg|Renviron|site)$|Dockerfile|/\.Rprofile$|/Makefile$|\.entitlements$|/go\.mod$'
  ls "$PUB"/*.sh "$PUB"/scripts/*.sh "$PUB"/t2t/*.sh "$PUB"/Dockerfile "$PUB"/t2t/Dockerfile "$PUB"/haproxy/haproxy.cfg "$PUB"/conf/*.conf "$PUB"/conf/*Renviron* "$NGX"/nginx.conf "$NGX"/default.conf "$NGX"/Dockerfile "$HOME"/bin/t2-contact-mail.* 2>/dev/null; }
# 7a. hosts
codefiles | sort -u | tr '\n' '\0' | xargs -0 -r grep -IhoE 'https?://[A-Za-z0-9._-]+' 2>/dev/null | sed -E 's#https?://##' | sort -u > "$TMP/hosts.found"
al_clean "$AL/hosts.txt" "$TMP/hosts.ok"
if [ $RAW = 1 ]; then echo "---- raw hosts"; cat "$TMP/hosts.found"; fi
unk=$(grep -vxFf "$TMP/hosts.ok" "$TMP/hosts.found")
[ -z "$unk" ] && pass "outbound hosts named in code: all $(wc -l < "$TMP/hosts.found") are on allowlist/hosts.txt" || fail "host(s) named in code but not on allowlist/hosts.txt" "$unk"
# 7b. pattern detectors
codefiles | sort -u | grep -E '\.R$|\.r$|\.Rmd$|\.Renviron|Renviron|Rprofile' | detector r-detector \
 'download\.file|\burl\(|curl::|httr|RCurl|socketConnection|\bsystem2?\(|\bpipe\(|eval\(parse|\bsource\(\s*["'"'"']?(https?|url)|Sys\.setenv|readRDS\(\s*url|\.Last\b|\.First\b|reg\.finalizer|\btrace\(|assignInNamespace|unlockBinding|install\.packages|install_github|remotes::|devtools::|dbConnect\(.*(host|MySQL)|writeBin|Sys\.chmod|\bshell\(|Sys\.getenv\((NULL)?\)|\.Call\(|dyn\.load|library\.dynam|sys\.source|setHook|options\(.*(repos|HTTPUserAgent)' r.txt
codefiles | sort -u | grep -E '\.swift$|\.plist$|project\.yml$|\.xcconfig$|\.entitlements$' | detector swift-detector \
 'URLSession|URL\(string|\bProcess\(|NSTask|dlopen|dlsym|NSClassFromString|performSelector|UserDefaults|@AppStorage|WKWebView|SFSafariViewController|Firebase|Analytics|Crashlytics|Sentry|identifierForVendor|ASIdentifierManager|UIPasteboard|CLLocation|SecItem|Keychain|Data\(base64|@_silgen_name|unsafeBitCast|OTHER_LDFLAGS|OTHER_SWIFT_FLAGS|NSAppTransportSecurity|NSAllowsArbitraryLoads|preBuildScripts|postBuildScripts|buildPhase|runScript|shellScript|scripts:' swift.txt
codefiles | sort -u | grep -E '\.sh$|\.py$|\.yml$|\.yaml$|Dockerfile' | detector shell-detector \
 '\|[[:space:]]*(ba|z)?sh([[:space:]]|$)|base64 +(-d|--decode)|\beval\b|\bnc\b|\bncat\b|/dev/tcp|mkfifo|crontab|systemctl +(enable|start|edit|daemon)|authorized_keys|\.ssh/|\bsudo\b|curl .*(--upload-file| -T | -F |--data(-binary)? +@| -d +@)|\bwget\b|\bscp\b|\bssh\b|rsync .*@|openssl +(enc|s_client)|xxd +-r|perl +-e|source +<|\. +<\(|git +(push|remote add|config)' shell.txt
codefiles | sort -u | tr '\n' '\0' | xargs -0 -r grep -HInE '[A-Za-z0-9+/]{150,}={0,2}' 2>/dev/null | relpath > "$TMP/b64"
al_anchor "$AL/base64.txt" "$TMP/al.b64"; rest=$(grep -vEf "$TMP/al.b64" "$TMP/b64" | cut -c1-200)
[ -z "$rest" ] && pass "base64-like blobs (150+ chars) in code: none outside the allowlist" || fail "long base64-like string in code" "$rest"
# 7c. credentials: unlisted = FAIL; known accepted findings = WARN
{ repo_files; ls "$PUB"/*.sh "$PUB"/scripts/*.sh "$PUB"/conf/* "$NGX"/*.conf "$HOME"/bin/t2-contact-mail.* 2>/dev/null; } | grep -vE '\.(png|ttf|db|xlsx|gz|zip|pdf|tif|tiff|ico|md)$|/(Data|TCGA/Data)/' | sort -u | tr '\n' '\0' | \
  xargs -0 -r grep -HInE 'AKIA[0-9A-Z]{12}|BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|xox[bpa]-[A-Za-z0-9-]{10}|sk-[A-Za-z0-9]{24}|AIza[0-9A-Za-z_-]{30}|password *= *["'"'"'][^"'"'"']+["'"'"']|\.p8\b|AuthKey_|api[_-]?key *[=:] *["'"'"'][A-Za-z0-9]|token *[=:] *["'"'"'][A-Za-z0-9_-]{16}' 2>/dev/null | relpath > "$TMP/sec"
red() { cut -c1-120 | sed -E 's/(password *= *")[^"]*"/\1<redacted>"/'; }   # display only, after matching
if [ $RAW = 1 ]; then echo "---- raw secrets-pattern hits"; red < "$TMP/sec"; fi
al_anchor "$AL/secrets.txt" "$TMP/al.sec"; al_anchor "$AL/secrets-known-findings.txt" "$TMP/al.seck"
rest=$(grep -vEf "$TMP/al.sec" "$TMP/sec" | grep -vEf "$TMP/al.seck" | red)
known=$(grep -Ef "$TMP/al.seck" "$TMP/sec" | cut -d: -f1 | sort | uniq -c | sort -rn)
[ -z "$rest" ] && pass "credential patterns: no unlisted hit" || fail "credential-like string in code" "$rest"
[ -n "$known" ] && warn "KNOWN FINDING (accepted, see README/report): hard-coded database passwords in legacy files; rotate and delete" "$known"
# code that reads credential files
{ repo_files; ls "$PUB"/scripts/*.sh 2>/dev/null; } | grep -E '\.(R|go|swift|sh|py)$' | tr '\n' '\0' | xargs -0 -r grep -HInE 'github\.token|t2-testflight\.env|\.appstoreconnect|private_keys|claude-oauth-token|\.ssh/id_|cookie\.env|\.netrc|\.git-credentials' 2>/dev/null | relpath > "$TMP/credread"
al_anchor "$AL/credential-readers.txt" "$TMP/al.cr"; rest=$(grep -vEf "$TMP/al.cr" "$TMP/credread" | cut -c1-200)
[ -z "$rest" ] && pass "code that reads credential files: only the documented iOS release tooling" || fail "code reads a credential file" "$rest"
# 7d. hidden characters
{ codefiles; repo_files | grep -E '\.(md|txt|json|html|tsv|csv)$'; } | sort -u | tr '\n' '\0' | xargs -0 -r grep -IlP '[\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2060}-\x{206F}\x{FEFF}]' 2>/dev/null | relpath > "$TMP/zw"
al_anchor "$AL/unicode.txt" "$TMP/al.zw"; rest=$(grep -vEf "$TMP/al.zw" "$TMP/zw")
[ -z "$rest" ] && pass "zero-width / bidi-control characters: none outside the allowlist" || fail "zero-width or bidi control characters in" "$rest"
{ codefiles; } | grep -E '\.(R|go|swift|sh|py)$' | sort -u | tr '\n' '\0' | xargs -0 -r grep -HInP '[^\x00-\x7F]' 2>/dev/null | grep -vP '^[^:]+:\d+:\s*(#|//|\*|///)' | grep -vP '"[^"]*[^\x00-\x7F][^"]*"|'"'"'[^'"'"']*[^\x00-\x7F][^'"'"']*'"'" | relpath > "$TMP/nonascii"
al_anchor "$AL/nonascii-code.txt" "$TMP/al.na"; rest=$(grep -vEf "$TMP/al.na" "$TMP/nonascii" | cut -c1-160)
[ -z "$rest" ] && pass "non-ASCII characters outside comments and string literals (homoglyph identifiers): none" || fail "non-ASCII character in code (possible homoglyph identifier)" "$rest"
{ repo_files | grep -E '\.sh$'; ls "$PUB"/scripts/*.sh "$PUB"/*.sh "$HOME"/bin/t2-contact-mail.sh 2>/dev/null; } | tr '\n' '\0' | xargs -0 -r grep -lP '\r' 2>/dev/null > "$TMP/cr"
[ ! -s "$TMP/cr" ] && pass "no carriage returns in shell scripts" || fail "carriage returns in shell script(s)" "$(cat "$TMP/cr")"
repo_files | tr '\n' '\0' | xargs -0 -r grep -IlE '.{3000,}' 2>/dev/null | grep -vE '/(TCGA|CPTAC|TCGATARGETGTEX)/[^/]*$|\.(csv|tsv|json|html|md)$' | relpath > "$TMP/long"
al_anchor "$AL/long-lines.txt" "$TMP/al.ll"; rest=$(grep -vEf "$TMP/al.ll" "$TMP/long")
[ -z "$rest" ] && pass "no code file with a 3000+ character line" || warn "code file(s) with a 3000+ character line" "$rest"

###############################################################################################
echo "== 8. git forensics =="
for r in "$REPO" "$SERVED" "$THANOS" "$NGX" "$PUB"; do
  [ -d "$r/.git" ] || continue
  h=$(find "$r/.git/hooks" -maxdepth 1 -type f -not -name '*.sample' 2>/dev/null)
  [ -z "$h" ] && pass "git hooks: none active in $r" || fail "git hook(s) active in $r (run on every commit/pull)" "$h"
  c=$(git -C "$r" config --local --list 2>/dev/null | grep -iE '^(core\.(hookspath|fsmonitor|sshcommand|pager|editor|gitproxy)|credential\.|url\..*\.(insteadof|pushinsteadof)|alias\.|filter\.|include|diff\..*\.(command|textconv)|merge\..*\.driver|http\.(proxy|sslverify|extraheader))')
  [ -z "$c" ] && pass "git config: no hook/proxy/credential/alias/filter override in $r" || fail "git config override in $r" "$c"
done
hg=$(git config --global --list 2>/dev/null | grep -iE '^(core\.(hookspath|fsmonitor|sshcommand|gitproxy)|credential\.|url\..*insteadof|alias\.|http\.(proxy|extraheader))')
[ -z "$hg" ] && pass "git config (global): no hook/proxy/credential/alias override" || fail "global git config override" "$hg"
ga=$( (cd "$REPO"; git ls-files '*.gitattributes' '.gitattributes'; cat .gitattributes 2>/dev/null) | head -5)
[ -z "$ga" ] && pass ".gitattributes: none (no filter/diff/merge driver, no linguist-generated hiding)" || warn ".gitattributes present" "$ga"
cat "$REPO/.gitignore" | grep -vE '^\s*(#|$)' | bl_check gitignore ".gitignore entries (a way to hide files from review)"
(cd "$REPO"; git log --all --since=2026-09-01 --diff-filter=A --numstat --format='C %h' | awk '/^C /{c=$2; next} $1=="-"{print c, $3}' | grep -vE '\.(png|ttf|jpg|pdf)$') > "$TMP/newbin"
[ ! -s "$TMP/newbin" ] && pass "git: no binary file other than fonts/images/PDF added since 2026-09-01" || fail "git: unexpected binary file added since 2026-09-01" "$(cat "$TMP/newbin")"
(cd "$REPO"; git ls-files -z | xargs -0 ls -l 2>/dev/null | awk '$5>5000000{print $5, $9}') > "$TMP/bigf"
al_anchor "$AL/big-files.txt" "$TMP/al.bf"; rest=$(grep -vEf "$TMP/al.bf" "$TMP/bigf")
[ -z "$rest" ] && pass "git: no tracked file over 5 MB beyond the allowlist" || fail "git: large tracked file" "$rest"
(cd "$REPO"; git for-each-ref --format='%(refname:short) %(objectname:short)' refs/heads refs/remotes refs/tags | grep -v 'origin/HEAD') | sort | bl_check git-refs "git refs (branches, remote branches, tags) of the repository"
nm=$(cd "$REPO"; git branch -a --no-merged main --format='%(refname:short)' | grep -v '^$' | tr '\n' ' ')
[ -z "$nm" ] && pass "git: every branch is merged into main" || warn "branches with commits not on main (review before merging or deleting)" "$nm"
(cd "$REPO"; git fsck --no-reflogs 2>&1 | grep -E '^(dangling commit|missing|broken|error)' | sed 's/dangling commit/dangling-commit/' | awk '{print $1, $2}' | sort) > "$TMP/fsck"
if [ -s "$TMP/fsck" ]; then bl_check git-fsck "git fsck: dangling commits / errors (old rebased or abandoned work)" < "$TMP/fsck"; else pass "git fsck: no dangling commit, no error"; fi
git -C "$REPO" stash list | grep -q . && warn "git stash is not empty" "$(git -C "$REPO" stash list | head -3)" || pass "git stash: empty"
git -C "$REPO" status --porcelain | grep -E '^\?\? ' | sed 's/^?? //' | sort | bl_check untracked "untracked files in the repository root (AI sessions leave files here; review new ones)"

###############################################################################################
echo "== 9. host persistence and permissions (readable without sudo) =="
{ crontab -l 2>&1; echo "-- /etc/cron.d"; ls /etc/cron.d 2>/dev/null; echo "-- cron.hourly"; ls /etc/cron.hourly 2>/dev/null; echo "-- cron.daily"; ls /etc/cron.daily 2>/dev/null
  echo "-- cron.weekly"; ls /etc/cron.weekly 2>/dev/null; } | bl_check cron "crontab and /etc/cron.*"
systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | sort | bl_check systemd-services "running systemd services"
systemctl list-timers --all --no-legend --plain 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /\.timer$/){print $i; break}}' | sort -u | bl_check systemd-timers "systemd timers"
{ find /etc/systemd/system -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.socket' \) 2>/dev/null | sort | xargs -r sha256sum; ls /usr/local/sbin/load-wan-guard >/dev/null 2>&1 && sha256sum /usr/local/sbin/load-wan-guard; } | bl_check systemd-unit-files "custom systemd unit files in /etc/systemd/system (sha256) and the firewall loader"
{ ls ~/.config/systemd/user 2>/dev/null; ls ~/.config/autostart 2>/dev/null; } | bl_check user-units "user systemd units and autostart entries (expected: none)"
[ -e /etc/ld.so.preload ] && fail "/etc/ld.so.preload exists (preloaded into every process)" || pass "/etc/ld.so.preload absent"
for f in ~/.Rprofile ~/.Renviron ~/.R/Makevars ~/.bash_aliases ~/.bash_profile ~/.bash_login ~/.pam_environment; do [ -e "$f" ] && fail "$f exists (executed or sourced at every login/R start)"; done
[ -z "$(ls ~/.Rprofile ~/.Renviron ~/.bash_aliases ~/.bash_profile ~/.pam_environment 2>/dev/null)" ] && pass "no ~/.Rprofile, ~/.Renviron, ~/.bash_aliases, ~/.bash_profile, ~/.pam_environment"
for f in ~/.ssh/authorized_keys ~/.ssh/authorized_keys2; do [ -f "$f" ] && awk '{print}' "$f" | grep -vE '^\s*(#|$)' | while read -r l; do printf '%s  %s  options=%s\n' "$(printf '%s' "$l" | sha256sum | cut -c1-16)" "$(printf '%s' "$l" | awk '{print $NF}')" "$(printf '%s' "$l" | grep -cE '^(command|from|environment|permitopen|no-)')"; done; done | bl_check authorized-keys "authorized_keys: hash of each key line, comment, forced-command options (key material never printed)"
ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/^\[::\]/*/; s/^0\.0\.0\.0/*/' | sort -u | BLLEVEL=warn bl_check listeners "listening TCP sockets"
# Claude Code permission rules: what an AI session may run without asking
perm() { python3 - "$1" <<'PY' 2>/dev/null
import json,sys,re
d=json.load(open(sys.argv[1])); a=d.get("permissions",{}).get("allow",[])
broad=re.compile(r'^(Bash\(\*?\)?|Bash)$|^Bash\((sudo|bash|sh|zsh|curl|wget|nc|ssh|scp|rsync|python3?|perl|ruby|node|Rscript|R|docker|git push|git remote|rm|chmod|chown|crontab|systemctl|eval|xargs|find|env|tee|dd|mv|cp)\b')
for r in a:
    if broad.search(r): print(r[:100])
PY
}
for f in ~/.claude/settings.json "$REPO/.claude/settings.local.json"; do
  [ -f "$f" ] || continue; p=$(perm "$f" | sort -u)
  al_clean "$AL/permissions.txt" "$TMP/al.perm"; rest=$(printf '%s\n' "$p" | grep -v '^$' | grep -vFxf "$TMP/al.perm")
  [ -z "$rest" ] && pass "Claude permissions ${f/#$HOME/\~}: no over-broad allow rule" || warn "Claude permissions ${f/#$HOME/\~}: over-broad allow rule(s): an AI session may run these without a prompt" "$rest"
done
python3 - <<PY 2>/dev/null | bl_check claude-allow-rules "Claude Code allow-rule lists (user settings and repo settings.local.json)"
import json,os
for f in (os.path.expanduser("~/.claude/settings.json"), "$REPO/.claude/settings.local.json"):
    try: d=json.load(open(f))
    except Exception: continue
    for k in ("allow","deny","ask"):
        for r in d.get("permissions",{}).get(k,[]): print(os.path.basename(f), k, r[:160].replace("\n"," "))
    for k in ("hooks","env","apiKeyHelper","statusLine"):
        if k in d: print(os.path.basename(f), k, "PRESENT", len(json.dumps(d[k])))
PY

echo
NP=$(wc -l < "$TMP/n.p"); NF=$(wc -l < "$TMP/n.f"); NW=$(wc -l < "$TMP/n.w")
echo "SUMMARY: $NP PASS, $NF FAIL, $NW WARN"
[ $WRITEBL = 1 ] && echo "(baseline/ rewritten from the current state: review 'git diff security/baseline' before committing)"
[ $NF -gt 0 ] && exit 1
exit 0
