# T2Mobile — working notes

Started 2026-10-04. Read this file first; it is kept current so the work can be
picked up cold (by Nathan, or by a later Claude session with no memory of this one).

## What this is

Two things, in one directory:

1. **`service/` — "gitr as a service"**: a small, fast, read-only HTTP service that
   answers one kind of question: *give me the per-sample values of these probes from
   tcga.db (or another T2 dataset)*. It is what `gitr()` does in the T2 R code, as an API.
2. **`ios/` — an iPhone app** with T2T's functionality (choose variables, filter samples
   interactively, plot, make publication figures). The app does all filtering, statistics
   and plotting **on the phone**; the only thing it asks the server for is data.

## Why (the reasoning behind the split)

T2T is a Shiny app: every visitor's every action runs in single-threaded R on the server.
Measured on 2026-10-04 (see /scratch/Docker/ShinyPublic/scripts/browser-tests/README.md):
about 12.5 CPU-seconds of server time per visitor (open the site + two plots), so even a
pool of 24 instances tops out near 100 new visitors a minute.

Almost none of that work needs the server. The only thing a client cannot do for itself is
read the 36 GB database. A request for one gene is ~13,000 numbers; everything after that
(filtering, regression, drawing) is trivial for a phone. So the server's job shrinks to an
indexed lookup that can be cached, and "hundreds of users" becomes easy.

## Layout

    NOTES.md            this file: status, decisions, how to run, what is next
    docs/API.md         the service's contract (endpoints, JSON shapes, semantics)
    docs/IOS.md         the app's design, and what Nathan needs to do on the Mac
    service/            the query service (Go), its Dockerfile, tests, load tester
    ios/                Swift sources: T2Kit (logic, testable on Linux) + the app

## Decisions taken (and why) — change any of these by telling Claude

- **Service language: Go**, not C++. The request said "C++ (or similar)". The workload is
  dominated by SQLite, so C++ would not be measurably faster, and a public-facing service
  that parses untrusted input is exactly where memory-safety matters. Go compiles to one
  static binary. The contract in docs/API.md is language-neutral, so a C++ (or Rust)
  reimplementation remains possible without touching the app.
- **SQLite driver: modernc.org/sqlite** (pure Go, no C at all). Databases are opened
  read-only and `immutable`, so there is no locking and nothing is ever written.
- **Data semantics are gitr's, exactly** (dense numeric view: tested-but-absent = 0,
  untested = missing; categorical view; clinical and virtual `cohort`/`subtype` columns;
  factor conversion from the `datatypes` table). An R test compares the API with `gitr()`
  value for value. See docs/API.md "Semantics".
- **Columnar responses aligned to a fixed sample order.** The app downloads the sample
  list and clinical table once per dataset; each probe is then just an array.
- **Responses are immutable and cacheable** (ETag + Cache-Control), so Nginx or a CDN
  can absorb repeat traffic. The service also keeps hot probes in memory.
- **No accounts or API keys yet.** Read-only public data, rate-limited at Nginx when it is
  published. Revisit before a public launch (see "Open questions").
- **iOS: SwiftUI, iOS 17+.** Logic lives in a Swift package (`T2Kit`) with no UI
  dependencies, so it can be compiled and unit-tested on Linux in Docker (there is no Mac
  here). The UI can only be compiled on Nathan's Mac.
- **Not published.** Nothing in this directory is reachable from the internet. The service
  runs only on an internal Docker network / localhost until Nathan says to publish it.
- **No git repository yet** (Claude does not commit unless asked). `git init` whenever you like.

## Status

(see the bottom of this file: "Log" — newest entry last)

## How to run the service here

    cd /scratch/nathan/R/T2/T2Mobile/service
    docker compose up -d --build          # builds the image, starts t2api on 127.0.0.1:3860
    curl -s http://127.0.0.1:3860/v1/datasets | head -c 400
    curl -s 'http://127.0.0.1:3860/v1/TCGA/values?probes=CD8A,TP53.mut' | head -c 400
    ./test.sh                             # equivalence with gitr() + load test

R is not installed on this host; the tests run R inside the `shinyt2t:2026.10` image.

## What Claude needs from Nathan

See docs/IOS.md "What you need to do". In short: a Mac with Xcode 15 or newer to build and
run the app in the simulator (free); an Apple ID to run it on your own iPhone (free, 7-day
installs); the Apple Developer Program ($99/year) only for TestFlight / App Store.

## Open questions (none block the current work)

1. Publish the service? Where: `https://www.fiveprime.org/api/...`? Needs an Nginx
   location (like T2Tc) and a decision on rate limits.
2. Should the app require a key, or stay open like the websites?
3. A covering index on `tcgai(probekey, type, samplekey, value)` would make cold lookups
   several times faster, at the cost of a larger database file and a rebuild. Worth it only
   if cold-probe latency turns out to matter (see Log for measurements).
4. App name and bundle identifier (placeholder: "T2", `org.fiveprime.t2`).

## Log

### 2026-10-04 — service built, tested, measured (Claude)

**Done**
- `service/`: Go service `t2api` (cmd/t2api), load-test client (cmd/loadtest), Dockerfile
  (static binaries in an empty image, 15 MB), docker-compose.yml (hardened like the public
  Shiny containers; 127.0.0.1:3860 + internal network `t2api-dev`; NOT public), `test.sh`.
- Contract: docs/API.md. Endpoints: datasets, meta (roles, defaults, presets, types),
  clinical, probes (search), values.
- **Equivalence with gitr(): ALL PASS** on TCGA, DEMO and tcgatargetgtex: sample order, all
  72 clinical/virtual columns, 194 probes covering every data type (48+40+85 numeric,
  13+3 categorical), missing values included. `./test.sh equiv`.
  - Found by the test: one text label in tcgatargetgtex contains an invalid byte
    ("Sympathetic\xcaNervous System", 162 samples). The API serves a space there. Worth
    fixing in TCGATARGETGTEX/build_tcgatargetgtex.R.
  - Pitfall hit while writing the test: in R, `levels[codes + 1]` silently DROPS elements
    where codes is -1 (index 0). Decode codes with an explicit mask.
- Hostile/malformed requests: all handled (`./test.sh abuse`).
- **Presets / default filters** (Nathan's request, 2026-10-04): the app is told which
  ready-made subsets to offer per dataset. They live in each database, in a table
  `default_filters` (Nathan: "the best place to put this is in the relational database").
  - Definitions + writer: `/scratch/nathan/R/T2/default_filters.R` (T2 repository).
  - Hooked into the builds: `TCGA/297-default_filters.R` (called from `TCGA/00-master.R`),
    `build_demo_dataset.R`, `TCGATARGETGTEX/build_tcgatargetgtex.R`. These edits are in the
    T2 working tree, NOT committed.
  - Existing database files were NOT modified. Until a rebuild, the service derives two
    presets from the roles. To add the table to an existing file without a rebuild:
    `Rscript default_filters.R write <db> <dataset>` (stop/restart whatever serves it).
  - Definitions validated read-only against the real databases (`... check <db> <dataset>`):
    TCGA 5 presets, tcgatargetgtex 6 (GTEx normal tissues = 7,429 samples; TCGA tumors
    9,807; TCGA matched normals 727; TARGET 734; all normal tissue 8,167; exclude cell lines
    18,698 of 19,131), DEMO 1. End to end shown on a scratch copy of DEMO.db.
  - No preset is on by default yet (`on = TRUE` in the definition switches one on).

**Measured (8 CPUs for the service, LLM not loaded)**
- A probe already in the service's memory: 3,100 requests/s (188,000/min) with 1,000
  concurrent clients, median 77 ms, 0 errors; 1,100/s with 200 clients, median 61 ms.
  Service memory 0.74 GB.
- The FIRST request for a probe (database lookup): about 12 probes/s in total, 0.1 s each
  when the file is in the OS cache, ~1 s when it is not, and many seconds each under 50+
  concurrent cold lookups. This is the bottleneck.
- Why: `tcgai` rows of one probe are scattered through the 36 GB table. The index
  `tcgaiidx_pts (probekey, type, samplekey)` finds them, but each of the ~11,000 values then
  costs its own row read. gitr() pays the same cost (it is why a new gene takes 1-2 s in T2).

**Next for the service (in order)**
1. **Covering index** `CREATE INDEX tcgai_cover ON tcgai(probekey, type, samplekey, value)`
   (and the same on tcgacati) in the database build. A probe then becomes one contiguous
   read of ~11,000 index entries (a few hundred KB) instead of ~11,000 scattered row reads:
   expect cold lookups in milliseconds, for the API *and* for T2/T2T. Cost: roughly 12-15 GB
   more in tcga.db and a longer build. NOT added to the pipeline yet: it needs Nathan's OK.
   No code change needed in the service (SQLite will pick the covering index by itself);
   re-run `./test.sh` after.
   To measure before committing to it: copy the rows of a few hundred probes into a scratch
   database, build both indexes, evict the file from the OS cache
   (`dd if=scratch.db iflag=nocache count=0`) and time both.
2. Publish: an Nginx location (pattern: T2Tc in /scratch/Docker/Nginx/nginx.conf), rate
   limits suited to an API, optionally `proxy_cache` so Nginx serves repeats.
3. A binary response format (raw float64) if JSON size ever matters; an access key if wanted.
4. Service settings worth knowing: `-cache-mb` (memory for cached columns per dataset,
   default 512 = ~8,000 TCGA probes), `-db-conns` (48), `-mem-limit-mb` (3072; container
   limit is 4 GB). With 64 MB page cache per connection the service reached 3.4 GB under
   load; it is 4 MB now (the OS file cache does the work) and stays under 1 GB.

### 2026-10-04 (later) — iOS core built and tested; app screens drafted (Claude)

- `ios/T2Kit`: Swift package (Models, APIClient, Filtering = presets + Thanos cross-filter,
  Stats). `swift test` in Docker: 12 tests, all pass. Reference values for the statistics
  came from R (see the test file's header).
      cd ios/T2Kit && docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -v "$PWD":/pkg -w /pkg swift:6.0-jammy swift test
- `t2smoke` (in the same package) against the running service: ALL PASS on the three
  datasets. This is the proof that the Swift client and the Go service agree.
      docker run --rm --network t2api-dev -u $(id -u):$(id -g) -e HOME=/tmp -v "$PWD":/pkg -w /pkg swift:6.0-jammy swift run t2smoke http://t2api:8080
  (Delete `ios/T2Kit/.build` afterwards; it is only a build cache.)
  Linux pitfalls already handled: `lgamma` is ambiguous on Linux (use `log(tgamma())`);
  networking needs `import FoundationNetworking` and the callback form of URLSession.
- `ios/T2App`: SwiftUI app, 5 source files + `project.yml` for XcodeGen. Syntax-checked with
  `swiftc -frontend -parse`; NOT type-checked or run (needs Xcode on Nathan's Mac).
- docs/IOS.md: design, what exists, what is not built, and the steps for the Mac.

**State of things outside this directory (so nothing is a surprise)**
- T2 repository working tree (`/scratch/nathan/R/T2`, branch main), UNCOMMITTED:
  new `default_filters.R`, new `TCGA/297-default_filters.R`, and one added step each in
  `TCGA/00-master.R`, `build_demo_dataset.R`, `TCGATARGETGTEX/build_tcgatargetgtex.R`.
- Docker: container `t2api` (image `t2api:dev`) is running, restart policy
  unless-stopped, 127.0.0.1:3860 only. Stop with `docker compose down` in `service/`.
- No database file was modified.

**Next (suggested order)**
1. Nathan builds the app on the Mac (docs/IOS.md) and sends back any compile errors.
2. Decide on the covering index (see the previous log entry): it is the difference between
   ~12 and thousands of *uncached* probe lookups per second.
3. Publish the service behind Nginx once the app runs against the tunnel.
4. App: survival screen, facets, on-device caching, TIFF, iPad layout.

### 2026-10-04/05 (night) — iPhone app: real compiles on macOS runners, mac_setup.sh (Claude)

Newest state of the iOS work is always the LAST bullet list of this entry ("Where it
stands"). docs/IOS.md is the reference; this is the history.

**Branch `t2mobile-ci`** (GitHub: NathanSiemers/T2). It is built on the *published* main
(789cc5d), not on the local main: the local main had an unpushed commit (5c8fc0e: query
service, default_filters, database build changes) and pushing a branch on top of it would
have published all of that. The branch therefore carries only `T2Mobile/ios`,
`T2Mobile/NOTES.md`, `T2Mobile/docs/IOS.md` and `.github/workflows/t2mobile-ios.yml`
(so docs/API.md and service/, which these notes mention, are not on it). A local-only
branch `t2mobile-ci-on-local-main` (bd68353) is the first, unpushed attempt; delete it at will.
Merging `t2mobile-ci` into main: the two NOTES.md / IOS.md versions will conflict trivially
(take this branch's for IOS.md; for NOTES.md keep both logs).

**CI** — `.github/workflows/t2mobile-ios.yml`, only for pushes to `t2mobile-ci` (and
manual runs); no secrets. Runner `macos-26` (arm64, macOS 26.6.2): **Xcode 26.6 (17F113),
iOS SDK 26.5**, simulators iOS 26.5 (iPhone 17 / 17 Pro / 17 Pro Max / 17e / Air), XcodeGen
2.46.0. Each job runs `T2Mobile/ios/mac_setup.sh --ci` — the script the owner runs on his
Mac — so the script itself is what is tested. A run takes ~6 minutes of work; waiting for a
free macOS runner took up to 20 minutes tonight.
    gh run list --limit 5            # (the gh here is 2.4: no --branch flag)
    gh run view <id> --log-failed
    gh run download <id> -D <dir>    # screenshots and logs

**Runs so far**
- 37268887380 (bc97f41): FAILED in step 5/7. One line: `var x = "", y = "", color = ""` in
  an `@Observable` class ("accessor macro can only apply to a single variable"). Rule: one
  stored property per `var` in @Observable classes. Steps 1-4 of the script passed.
- 37275226366 (fafbf8c): **GREEN**. The draft app as written on Linux compiled with that one
  fix. T2Kit: 45 tests pass on macOS. The script ran all 7 steps: XcodeGen downloaded
  (no Homebrew), project generated, simulator booted (2.5 min cold), app installed and
  started on each of its four tabs, loaded live TCGA data, four screenshots saved.
  What the screenshots showed (draft UI): data and plot correct in substance (boxes of CD8A
  by cohort, 12,804 samples), but x-axis labels overlapping the axis title, legend cut off,
  filter histogram labels one letter wide with 33 switches, figure preview far down the
  Publish form. The live service was already serving stored presets ("Tumor samples only",
  "Primary tumors only", ...).

**Built this night (all in `T2Mobile/ios`)**
- `mac_setup.sh` (see docs/IOS.md "On the Mac: one command").
- `T2App/project.yml`: app + UI-test target + scheme; `Config/T2.xcconfig` (bundle id
  `org.fiveprime.t2`, version 0.2.0 build 1, team empty; `Config/Local.xcconfig` overrides,
  not in git); iOS 17.0; iPhone only; portrait + landscape; icon and launch logo generated
  by `tools/make_icon.py` (Pillow; committed PNGs); accent colour.
- T2Kit additions, each tested against R 4.5.3 / survival 3.8.6 (the R containers used for
  the reference values were `shinyt2t:2026.10`; scripts are quoted in the test files):
  `StatsMore` (Pearson/Spearman p, Kruskal-Wallis, KM confidence limits, Cox, quantile
  groups as survival_km(), residuals), `Palette` (plasma from viridisLite), `PlotScene` +
  `PlotBuilder` (a plot as data: scatter and box plots so far).
  Semantics taken from lib.R, with line numbers checked: z-score and probe combination run
  over the samples in use (after gitr() filtering), before the "complete information" cut;
  "remove influences of" is fitted after that cut, over the samples drawn; "complete
  information" also requires the dataset's `cohort` and `sample_type` when it has them.
  Real numbers to compare with the website: TCGA, X = cohort, Y = CD8A, colour =
  sample_type, no filters: 11,005 points (CD8A missing for 1,753 samples, cohort for 213).
- Facts about the live API found on the way (client-side handled, API-side worth fixing):
  `meta.survival_endpoints` lists OS/PFI/DSS/DFI for every dataset, but tcgatargetgtex
  and DEMO have no such columns (T2Kit: `usableSurvivalEndpoints`).

**Pitfalls**
- This host's worktree guard refuses long compound shell commands; edit files with the
  editor tools and run one plain command at a time.
- Linux Foundation: `String(format: "%@", swiftString)` is not usable; interpolate.
- XCUITest: an element in a SwiftUI List exists only while it is on screen: scroll first.
- `xcrun simctl launch --stdout=file` returns at once and the app's output lands in the
  file; the app writes `T2-READY <dataset>` with FileHandle (print() would be buffered).
