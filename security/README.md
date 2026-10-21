# security/ : the repeatable backdoor audit

Run it after every round of AI work (and before every deploy):

    security/scan.sh            # everything; the Go rebuild needs docker + network (about 2 minutes)
    security/scan.sh --quick    # skips the Go rebuild; compares the live binary with the hash the last full run proved
    security/scan.sh --raw      # print the unfiltered hits of the pattern detectors (to review or extend an allowlist)
    security/scan.sh --baseline # (re)write baseline/ from the CURRENT state, after a human reviewed it

Output is one `PASS` / `FAIL` / `WARN` line per check and a final count; the exit status is 1 on any FAIL.
It is read-only: it writes only to `security/baseline/` (with `--baseline`) and to a `mktemp` directory. No sudo, no
`docker compose`, no change to any container, image, service, cron entry or firewall rule. Secrets are never printed
(only names, counts, hashes, and the first characters of lines from which password values are blanked).

## Threat model

An AI coding session (many have edited these code bases) can write a backdoor into the code, the configuration, the
build or the host: an outbound call that leaks queries or credentials, a hidden route or magic value in the Go service,
a changed deploy step, a widened mount or permission, a compose or nginx change that exposes more than documented, a
binary in production that does not match the source, an extra SSH key or cron entry. Comments and documentation are
untrusted: the suite looks at what the code and configuration DO now, and compares with a reviewed baseline.

Because the AI sessions can edit anything they can write, the suite also protects itself: `baseline/m-security`
holds the hash of `scan.sh` and of every `allowlist/*.txt`, so a weakened check or a widened allowlist is a FAIL until
a human accepts it. The final judge is you reading `git diff security/` before you commit it. Run the suite from a clean
state you trust, and never let the session that is being audited accept its own baseline.

## What it checks

1. Integrity manifests (sha256 against `baseline/`): Nginx stack, ShinyPublic stack (compose, Dockerfiles, entrypoints,
   haproxy, conf, scripts), host files (`~/bin/t2-contact-mail.*`, `.bashrc`, `.profile`, `~/.claude/settings.json`, the repo's
   `.claude/settings.local.json`), repo ops/build/release files (`deploy.sh`, `test.sh`, `allow-deploy.py`, Dockerfile, go.mod/sum,
   iOS tooling, CI), and the suite itself. The cron mail script must equal the reviewed copy in `T2Mobile/ops/contact`.
2. Served code: `/scratch/shinyusb/T2T` has no modified, untracked or ignored file beyond `allowlist/served-untracked.txt`
   and its HEAD is an ancestor of the repository's `main` (a WARN if it is behind by code changes); Thanos is clean and
   equals its `origin/main` and the baselined commit.
3. Running containers: image ids, privileges, networks, entrypoints, mounts and env var NAMES (baseline); a privilege
   lint (privileged, host net/pid, cap_add, devices, docker.sock, `/` mount); `docker diff` of every production
   container (only runtime files allowed); the nginx config in the container equals the file; the R site profile files
   inside the Shiny images; the build history of the production images.
4. Go service: mux routes (baseline + each documented in `docs/API.md`), dependencies (baseline + only modernc.org/sqlite and its
   known transitive set), a detector over the sources (exec, dial, http client, unsafe, syscall, init, linkname, embed, cgo,
   os.Getenv, file writes, every header and query parameter read, literals compared with request values), `go mod verify`,
   and a rebuild of `cmd/t2api` in a throwaway `golang:1.23-alpine` container compared byte for byte with the binary in
   `t2api` and `t2api-web`.
5. Nginx semantics: no mirror/post_action/sub_filter/js/lua/perl/auth_request/autoindex/alias/stream; proxy_pass targets,
   `set $app` names, upstream server, return/rewrite targets, log files, includes, `if` blocks and `add_header` lines are exactly
   the documented ones; the list of `location` blocks is baselined.
6. Compose and Dockerfile lint, the bind-mount list, and the image/entrypoint/command lines (baseline).
7. Outbound hosts named anywhere in code (allowlist `hosts.txt`), pattern detectors for R, Swift/plist/project.yml and
   shell/YAML/Dockerfile, base64 blobs, credential patterns (unlisted = FAIL, known accepted findings = WARN), code that
   reads credential files, zero-width/bidi characters, non-ASCII outside comments and strings, CRLF in scripts, very
   long lines.
8. Git: active hooks, config overrides (hooksPath, fsmonitor, sshCommand, credential helpers, aliases, filters, url rewrites) in
   the five repositories, `.gitattributes`, `.gitignore` entries (baseline), binary files added since 2026-09-01, large tracked
   files, branches and tags (baseline), branches not merged into main, dangling commits (baseline), stash, and the list of
   untracked files in the repo root (baseline).
9. Host persistence readable without sudo: crontab, `/etc/cron.*`, running systemd services and timers, user units and autostart,
   `/etc/ld.so.preload`, `~/.Rprofile`/`.Renviron`/`.bash_aliases`..., `authorized_keys` (hash of each line + comment +
   forced-command options; key material never printed), listening TCP sockets (WARN level), and the Claude Code
   allow rules (baselined; over-broad rules such as `Bash(curl *)` or `Bash(Rscript:*)` are a WARN).

## Allowlists

`allowlist/*.txt`: one extended regex per line, matched against `path:line:text` of a hit (paths are relative to the repo
root). A `#` line above an entry says why the hit is legitimate. Be stingy: an entry must be justified by the code's
documented purpose, and should name the file and the construct, not a whole directory. A new hit in a file that already has
entries is still a FAIL until the new line is looked at. `secrets-known-findings.txt` holds findings that are real but
accepted for now; they print as a WARN every run so that they are not forgotten.

## Accepting a legitimate change

1. Run `security/scan.sh`; read every FAIL and the `diff` it prints.
2. Decide: is the change intended and benign? If it is a pattern hit, add a justified line to the matching allowlist; if it is a
   baseline difference, nothing to edit.
3. Run `security/scan.sh --baseline` (this rewrites `baseline/`, including the hash of the suite itself), then `git diff security/`,
   and commit only what you understand.

## What it cannot see

- Anything that needs sudo or root: `/etc` outside the readable parts, root's crontab and `/var/spool/cron`, the firewall,
  other users' files, `/etc/ssh/sshd_config`, `auditd`, systemd unit files that are not world-readable, the root authorized_keys.
- A tampered kernel, bootloader, Docker daemon, or a rootkit that hides from non-root tools.
- Binary tampering inside images other than the Go binary (nginx, haproxy, R, shiny-server, base images, R packages): only their
  build history, ids, config and R site files are checked. A malicious R package in a pulled layer is invisible.
- The Mac (Xcode project, keychain, `~/.appstoreconnect` contents) and the GitHub repository's server-side settings (deploy keys, actions secrets).
- Network behaviour at run time (it reads code, it does not capture traffic); data poisoning in the downloaded source files.
- A backdoor written in a way no pattern matches (the detectors are patterns plus baselines; new Go or R logic that
  branches on a request value is flagged only by the literal-compare and header/query detectors). Review the diff of
  the commits since the last clean run with your own eyes: `git log -p --since=<date> -- T2Mobile/service T2Mobile/ops`.
- The other public Shiny apps (AllNets, PC3, SCMel, SCBlood, GENIO) are covered at the container level (mounts, privileges, `docker diff`),
  not by code scan; the legacy `shiny` container is included in the container baseline.
