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

(details at the bottom of this file: "Log" — newest entry last)

As of 2026-10-07 evening (commit 8e75fbc): **T2 0.2.0 is on Nathan's iPhone through
TestFlight** (App Store Connect app "T2 Cancer Genomics", bundle id `org.fiveprime.t2`,
internal group "Internal" with access to all builds; the next upload is one command, see the
log entry "TestFlight"). Service live and current (image `t2api:2026.10`, rollback
`t2api:pre-cohorts-20261007`): TCGA's `defaults` now carry `cohorts` (nine of 33) and the app
opens with that cohort filter. App at feature parity with the website for selection, presets,
cross-filter, box/scatter/survival/count plots, facets, combined and individual Y probes,
conditioning, export of figures and of the data table; all of Nathan's notes through the
8:27 pm 6 Oct entry of `app.notes.md` done. Tests: T2Kit 57, FigureTests 7, UI 6 (all green
on the Mac, Xcode 27 / iPhone 18 Pro).

**1.0 submitted to App Review 2026-10-07 evening** (WAITING_FOR_REVIEW; release automatic
after approval; see the log entry "App Store listing"). Privacy and support pages live at
fiveprime.org/t2app/; the service logs no successful request.

**Branch `post-1.0`** (2026-10-09): Nathan's rule while 1.0 is in review — the code given to
Apple (`main` at 425927d) is not touched; everything after goes on this branch and he merges.
On it: two UI-test fixes for 4.7" screens. **Simulator matrix 2026-10-09** (`ios/tools/sim_matrix.sh`,
log entry "Simulator matrix"): all six UI tests green on iPhone SE (3rd gen), 13 mini, 17e,
17, Air, 18 Pro, 18 Pro Max, light and dark on every one (14 runs, 84 test passes).

**Night of 2026-10-09/10 — the back-port (branch `post-1.0`, commits 8e1dd54, 8501019 and the
one after; log entry "Back-port")**: the Shiny app gained the app's data sources and
ready-made subsets (from the database, via one rule shared with the app), can run over the
service (`T2_API_URL`), ranked search, clinical descriptions, the contact form, a count
display for two categoricals; the service decides every dataset fact once (`/meta
sources`, preset counts, `/probes?all=1`) and refuses floods (`-max-inflight`); a
portable standby unit (`standby/`) was built and measured; the production switch of the
Shiny sites to the new code base is planned in `docs/PRODUCTION-SWITCH.md` and waits for
Nathan's "deploy". The 1.0 app's six UI tests were run on the simulator against the changed
service (tunnelled to the Mac). Nothing was deployed: production service, sites, Nginx and
the served databases are as they were.

Next, in order of Nathan's interest: (0) a backup server for the API and a way to switch DNS
to it when the house loses power (Nathan, 2026-10-07; plan and open decisions in
`docs/FAILOVER-PLAN.md`); (1) the Model screen — see "Plan: group comparisons and
linear models" in the log (not started); (2) whatever TestFlight on the real phone turns up
(Nathan's feedback comes through TestFlight > Feedback in App Store Connect or the in-app
form); (3) show the clinical descriptions on the Shiny site's About tab; (4) no test
statistics on box plots until real models exist (Kruskal-Wallis removed 2026-10-07).

How Claude runs the Mac (2026-10-06/07): `rsync -az --delete` of `ios/` to
`nathan@10.13.13.4:~/Claude/T2Mobile/ios/` excluding `.build/`, `Info.plist`, `build/`,
`tools/`, `screenshots/`, `logs/`, `*.xcodeproj`, `Local.xcconfig` (forgetting `.build/`
once pushed a Linux build cache onto the Mac; `rm -rf ios/T2Kit/.build` there fixes it), then
`./ios/mac_setup.sh --ui-tests` over ssh in the background (~20 min; without `--ui-tests` the
script stops after the simulator screenshots). A single UI test reruns in ~3–4 min with
`xcodebuild ... build-for-testing` then `-only-testing:T2UITests/T2UITests/testNN_... test-without-building`
with `TEST_RUNNER_T2_SCREENSHOT_DIR` set; screenshots land in `screenshots/ui-*/`.

## How to run the service here

    cd /scratch/nathan/R/T2/T2Mobile/service
    docker compose up -d --build          # builds the image, starts t2api on 127.0.0.1:3860
    curl -s http://127.0.0.1:3860/v1/datasets | head -c 400
    curl -s 'http://127.0.0.1:3860/v1/TCGA/values?probes=CD8A,TP53.mut' | head -c 400
    ./test.sh                             # equivalence with gitr() + load test

R is not installed on this host; the tests run R inside the `shinyt2t:2026.10` image.

## What Claude needs from Nathan

See docs/IOS.md "What you need to do". The Mac is in place (ssh, Xcode 27). Still needed:
the Apple Developer Program membership to become active (agreement signed, account
`nosapple@fiveprime.org` logged into Xcode on 2026-10-06, never asked to pay) and its Team
ID, for installs on his and friends' phones (TestFlight) — `mac_setup.sh --team ID` is ready.
Decisions for the Model screen (plan in the log): which R packages beyond lm/emmeans/limma,
and whether the model service may live beside t2api in ShinyPublic.

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
- 37276335636 (5e663c6): the reworked app (plots drawn from T2Kit scenes, new Select / Plot
  / Filter / Publish screens) **compiled first time**; job `mac-setup` green. The three
  UI-test jobs each ran 5 flows: 4 passed on every device (iPhone 17 Pro Max, iPhone 17 Pro
  in dark mode, iPhone SE 3rd generation, which the script created itself; the SE job also
  took the Homebrew route to XcodeGen). The one failure was the TEST's expectation, not the
  app: with no cohort ticked, 213 samples remain, because a sample with no cohort value
  passes a filter unless "include samples with no value" is off (Thanos semantics).
  Seen in the screenshots (34 per device): default box plot (11,005 points, as computed
  from the API beforehand), gene / mutation / clinical search, scatter with fit line and
  statistics, numeric colour and size, no-match search, presets (tcgatargetgtex offers
  "GTEx normal tissues" ... from the database), cross-filter with live counts, both page
  presets on Publish, PNG and PDF export, the share sheet with the PDF, dataset menu, DEMO,
  unknown probe, no connection. Fixed afterwards: tinted labels inside buttons, long share
  labels, legend rows, test scrolling.
- 37278262683 (9bfc855): **all four jobs GREEN**: setup job, and six UI flows on iPhone 17
  Pro Max, iPhone 17 Pro (dark) and iPhone SE. This is the run whose screenshots were
  looked at for survival, graph-for-each, counts, cohorts, the table and the no-samples
  flow (docs/IOS.md "How far each part has been checked").
- 37306211658 (1d12154): TIFF export, "Combine and adjust" on Select, a macos-15 job.
  Run conclusion: FAILURE, for one job. macos-26: setup job green; UI tests green on
  iPhone SE and iPhone 17 Pro dark (all six flows, TIFF and combine/adjust included);
  on iPhone 17 Pro Max flow test04_Publish failed ("the share link did not appear"): the
  failure screenshot shows the "Plot: PNG" row at the edge of the floating tab bar after
  scrolling, so the test's tap did not reach the button. A weakness of the test helper
  (`scrollTo`), which now drags such an element further up; the same flow passed on the
  other two devices. The macos-15 job (Xcode 16.4, iOS SDK 18.5,
  information only) FAILED in step 5/7 on one line: "the compiler is unable to type-check
  this expression in reasonable time" for a chain of six `+` on arrays in
  `AppModel.writeTable`. Rewritten as appends in the next commit. Rule: no long `+` chains
  of array literals; Xcode 16's type checker gives up where Xcode 26's does not.

- 37308564682 (572b1f9): **macos-15 job GREEN: the app builds and runs with Xcode 16.4**
  (iOS SDK 18.5) after the one-expression change, as it does with Xcode 26.6. UI tests
  green on iPhone 17 Pro Max (the Publish flow now passes there) and iPhone 17 Pro dark.
  On the iPhone SE flow test02 failed with "could not scroll to pick-X": the drag added to
  `scrollTo` in that commit left the Select list scrolled down on the small screen, and
  the helper only looked downward. It now also scrolls back up (next commit). Again a
  test-helper problem; the app code is the same as in the jobs that passed.

**Where it stands (end of the night of 2026-10-05)**
- Branch `t2mobile-ci`; every commit is pushed. The last run with EVERY job green is
  37278262683 (commit 9bfc855). The commits after it add TIFF export and "Combine and
  adjust" (1d12154: built with Xcode 26.6, all UI flows passed on two of three devices, see
  above), then change one expression in `AppModel.writeTable` (for Xcode 16), the UI
  tests' `scrollTo` helper (twice), and these notes. No app source changed after 572b1f9.
  Look at the newest run of workflow
  "T2Mobile iOS" for the result of the last commit: `gh run list --limit 3`. If it is red
  for a reason that is not obvious, `git checkout 9bfc855 -- T2Mobile/ios` gives back the
  fully green app.
- What the owner does: on the Mac, `/path/to/T2/T2Mobile/ios/mac_setup.sh` (docs/IOS.md,
  first section). Nothing else is needed for the simulator; the script prints the steps
  for his own iPhone (free Apple ID) and for the paid membership.
- Screenshots Claude looked at were downloaded to this host's session scratchpad
  (`.../scratchpad/run4/ui-*/screenshots/`), which is temporary: get them again with
  `gh run download 37278262683 -D <dir>` (artifacts are kept 90 days).
- Not done, in order of value: see docs/IOS.md "Not built (explicit gaps)" and "Known
  cosmetic flaws". Next sensible steps: open the exported PNG / TIFF / PDF / CSV files and
  check size, dpi and content; run on a real iPhone; multi-Y facets; cache data on the
  device; the About tab.
- For the API side (nothing blocks the app): `meta.survival_endpoints` lists OS, PFI,
  DSS, DFI for datasets that have no such columns (the app checks the clinical columns
  itself); an endpoint that returns only the non-missing samples of a probe, or a binary
  format, would shorten downloads but is not needed.
- Helper containers `ios-swift` / `ios-r` (Linux Swift builds, R reference values) were
  temporary and are removed; the commands to recreate them are in docs/IOS.md and in the
  test files' headers.

### 2026-10-05 — databases rebuilt, service hardened and redeployed, branch merged (Claude)

**Service is public**: `https://www.fiveprime.org/api/t2/` (`/healthz`, `/v1/...`; `/statz`
is not exposed). Production container `t2api` is defined in
`/scratch/Docker/ShinyPublic/docker-compose.yml` (image tag `t2api:2026.10`, 127.0.0.1:3860,
network `shinypublic`, read-only root, user 999, 4 GB without swap) behind Nginx
(`/scratch/Docker/Nginx/nginx.conf`, 50 requests/s per IP). `service/docker-compose.yml` is
only a stand-alone development instance.

**Databases** (all three rebuilt on 2026-10-05 from the fixed pipeline, no downloads; the
service reads copies in `/scratch/shinyusb/T2-rebuilt-20261005/`; the Shiny sites still read
the July files in `/scratch/shinyusb/T2` until the owner says otherwise):
- covering index `(probekey, type, samplekey, value)` on both fact tables: one probe is one
  contiguous index read (uncached lookup about 20 ms);
- table `default_filters` (the presets), table `sparse(type, sparse, default_value)`: how
  each data type was loaded. A sample tested for a type with no stored row gets the default
  (0) only when the type is sparse; for a type loaded in full it is missing. A stored NULL
  and an untested sample are missing either way. `dataset.go` reads the table (`loadSparse`)
  exactly as the view `tcgas` uses it;
- signatures (`.sig`) are missing unless every member gene has a value: the 1,744 samples
  without RNA no longer get an invented number;
- a sample that occurs twice in a source file is the mean of its copies (nine samples had no
  RNA at all before because both copies were renamed by the reader);
- lists in `dataset_meta` are separated by `|` (a cohort name contains a comma);
  `splitMeta` in `dataset.go` reads both forms;
- when a sample has several values of one categorical probe (two mutations of a gene),
  `gitr()` and the service both keep the smallest value in byte order (it used to depend on
  the index).
`service/test.sh equiv` (value-for-value against `gitr()`): ALL PASS on the three datasets
after each of these steps and after the deployment.

**Hardening (commit 03a14e0), all in `test.sh abuse`:**
- every requested name is checked in memory against the dataset's variable list
  (`allprobes` + `probes` + clinical columns) before any query; unknown names cost nothing
  and are never cached (2,000 made-up names: cache unchanged, 88 MB resident);
- at most 100 names per call; a call whose first 10 names are all unknown is refused (400);
- `?v=<version>`: the answer comes only from that database build (cacheable for good) or is
  `409`; without it `max-age=300` + ETag; `/values` bodies carry `version`; the ETag is a
  fixed-length hash;
- the service answers `503` and exits (Docker restarts it) when the file it loaded is
  replaced or rewritten: sample order, key maps and cached columns belong to one file.
  **Replace a database by a new directory + volume change + `docker compose up -d t2api`,
  never by copying over a served file** (docs/API.md, "Replacing a database");
- a panic while loading a column is an error for the waiting requests, not a name stuck
  pending; handler panics give a plain 500;
- driver `modernc.org/sqlite v1.38.2`: v1.34.1 took one process-wide lock for every SQLite
  mutex operation, so uncached lookups ran one at a time.

**Measured after hardening** (private instance, 8 CPUs, TCGA, rebuilt database):

| Load | before | after |
|---|---|---|
| 200 clients, 3,000 probes, half the requests uncached | 50 requests/s, median 4.6 s | 1,582 requests/s, median 68 ms, p99 1.2 s |
| 500 clients, 300 probes, mostly cached | about 3,100 requests/s | 3,211 requests/s, median 66 ms |

Memory 157 MB after start-up and cold load, 1.1 GB with the caches full (limit 4 GB).
One instance is enough for hundreds of simultaneous phones; gzip is now the main cost of
the warm path (API-6 of the review: cache the compressed column) and the uncached columns
of one request are still fetched one after another (API-9). A pool of instances behind
Nginx/HAProxy needs nothing shared (each has its own cache) and is the next step only if
one instance's 8 CPUs are ever saturated.

**App**: `T2Kit.APIClient` passes the dataset version, treats `409` as "the database was
replaced" (the app reloads the dataset rather than attach new values to the old sample
order), retries `503`, and sends up to 100 names per request. `t2smoke` checks the refusal
of a stale version against the live service. Branch `t2mobile-ci` was merged into `main`
on this date; continue on `main` and push to `t2mobile-ci` when a Mac build is wanted (the
workflow only runs for that branch).

**Open**: authentication / per-key limits (none yet); API-6 and API-9 above; the Shiny
sites and the API read different database generations until the live Shiny files are
replaced.

### 2026-10-06 — Nathan's first use of the app; contact form; Mac access (Claude)

Nathan built the app on his Mac (Xcode 27, iPhone 18 Pro simulator) and kept notes in
`/scratch/nathan/R/T2/app.notes.md`. Everything there is done:

- search field: `.searchable` replaced by a plain `TextField` with `FocusState` inside a
  stable `List` (the search list no longer loses focus after one character);
  results ranked by the service (exact, prefix, contains; shorter first), 200 per query;
- slider knobs tinted; the API URL is no longer shown; About panel (`?`) with the data
  types and a "Private deployments" note; the DEMO dataset is hidden from the data sources;
  colour-by-category dodges the boxes; a full-screen plot (close button fades after a
  moment, reappears on touch) for screenshots;
- data sources: "TCGA tumors" is **`tcga.db`** (not the Toil TCGA part), "GTEx normal
  tissues" and "TARGET pediatric cancers" are presets over `tcgatargetgtex` (`AppModel.
  DataSource`, `subsetSources`, `fixedPreset`, `availableCohorts`);
- stickiness: on a data-source switch the X/Y/colour/size/facet names and the filter
  panels — including their checkbox and range settings — survive when the names exist in
  the new dataset (`Carried` in `AppModel.open()`); `CrossFilter.levelsPresent` restricts a
  categorical panel to the levels present in the chosen source;
- **a categorical filter panel with one present level is not shown** (Nathan: the study
  choice is unnecessary inside the GTEx part; "study must exist when there's more than one
  choice available"). test05 now asserts the `study` panel in the whole collection and
  its absence inside the GTEx part;
- quick multi-pick of probes (`VariableSearch(multiple:)`, `pickMany` in the UI tests).

**Contact form** (About → "Contact the author"): `POST /api/t2/v1/contact` (`contact.go`):
fields cut to one line / paragraphs, control characters removed, honeypot field, minimum
3 s between opening the form and sending, 5 per IP per hour and 200 per day, body 16 KB,
Nginx 1 request/min per IP (burst 3) with `client_max_body_size 32k`. The service only
**appends a JSON line to `/scratch/shinyusb/t2-contact/messages.jsonl`** (volume
`/contact`, `T2_CONTACT_DIR`) — no mail credentials anywhere near the container. Delivery:
Postfix on the host, **local-only** (`inet_interfaces = loopback-only`, `default_transport
= local`), and a cron job every 15 min (`~/bin/t2-contact-mail.sh` → `~/bin/
t2-contact-mail.py`, state in `~/.t2-contact.state`, log `~/.t2-contact.log`) that mails
each new line to local user `nathan` (`mail` on the server; Subject "T2 contact: name
(affiliation)", Reply-To the sender when the address is valid) and appends it to
`/scratch/shinyusb/t2-contact/inbox.md`. The address T2@fiveprime.org appears nowhere in
the app. `messages.jsonl`/`inbox.md` must stay group-writable (664, nathan:bioinfo) for
the container (uid 999) to append.

**Mac**: Nathan opened ssh to his MacBook (`10.13.13.4`, `~/Claude/T2Mobile`) and allowed
Claude to sync and run the build script there. Sync with `rsync -az --delete` **excluding
`Info.plist`** (generated by the script; deleting it breaks a direct `xcodebuild`), the
`build/`, `tools/`, `screenshots/`, `logs/` folders and `*.xcodeproj`. Run
`ios/mac_setup.sh --no-open --ui-tests --device "iPhone 18 Pro"` in place; a full UI run
takes 13–15 minutes. Do not redeploy the API while a UI run is going (a 409 fails every
test). Test cycles are delegated to a low-cost agent.

### 2026-10-06 (evening) — Nathan's second round of notes (Claude)

From `app.notes.md` (4:56 pm entry):

- **Export (PNG/TIFF/PDF)**: a progress line while rendering (ImageRenderer is main-thread; the
  file is encoded off it), files kept in **Documents/Figures** (shown by the Files app under
  On My iPhone › T2 › Figures; `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`),
  **Save to Photos** for PNG/TIFF (add-only permission, `NSPhotoLibraryAddUsageDescription`),
  Share stays. The simulator's share sheet is unreliable; Files and Photos are not.
- **Legend**: no "+ N more" anywhere. `SceneDrawing.legendPlan` (pure, no GraphicsContext)
  places every entry: beside the panel only when all fit in one column at full size; else
  under the panel with as many columns as fit at natural width or as the height requires,
  the type reduced (never below 5 pt) only when `shrink` is allowed (fixed-size figures).
  The Plot screen passes `legendRoom: true` and grows by `legendHeightBelow` so the legend
  is complete at full size there.
- **Plot fills the screen**: the Plot tab's canvas is the visible height (GeometryReader, so
  it follows the orientation), full width (`listStyle(.plain)`, no row insets); the sample
  count sits ABOVE the plot where it stays visible; a new plot is shown from the top
  (`onAppear` + ScrollViewReader).
- **Panels per row** (`PlotStyle.facetColumns`, 0 = automatic) on the Plot screen's
  Appearance section and the Publish screen's sizes section, drawn by `panelColumns`.
- **FigureTests** (`T2App/Tests`, target `T2AppTests`, runs in the simulator after the build in
  `mac_setup.sh`, `-only-testing:T2AppTests`): renders figures to pixels and checks that each
  type size, the point size, the legend and the source line change the ink as they should,
  that every legend entry is placed however little room there is, and that `facetColumns`
  takes effect. Measures ink ADDED over a bare figure (axes, grid and boxes are always drawn).
- **Clinical variables explained**: `service/cmd/t2api/clinical_descriptions.tsv` (column,
  datasets, description, source) is embedded in the service and served in `/meta` as
  `clinical_descriptions` for the dataset's columns; the About panel lists them under
  "Clinical variables". Sources: TCGA-CDR (Liu et al., Cell 2018) for the clinical fields and
  the OS/DSS/DFI/PFI definitions, the Pan-Cancer Atlas subtypes table, Thorsson et al. 2018 for
  the immune subtypes, the Toil phenotype file. **The Shiny site does not show these yet**
  (its About tab lists only the data types) — a follow-up.
- UI-test lessons: `isEnabled` of a toolbar button is unreliable on the GitHub runners' iOS
  (Xcode 26) though fine on the Mac (Xcode 27/iOS 27): the contact form exposes
  `accessibilityValue` "ready"/"incomplete" instead. A List reports only on-screen rows, so a
  long section (56 clinical variables) must be scrolled to.
- Service image `t2api:2026.10` rebuilt and redeployed for the descriptions (rollback tag
  `t2api:pre-clinical-20261006`).

Apple: Nathan signed the Program agreement and logged `nosapple@fiveprime.org` into Xcode, but
was never asked to pay, so the paid membership is probably not active yet; no team chosen in
Xcode, no signing certificate. `mac_setup.sh --team ID` is ready for when the Team ID is known.

### 2026-10-06 (night) — export table, sample presets per data source, model plan (Claude)

From `app.notes.md` (8:27 pm entry):

- **Export table** (Plot screen › Table): one row per sample in use, exactly as the presets and
  the filters leave them (`filter.mask()`), with EVERY probe asked for in this dataset so far
  (plotted ones first, then the filter columns, then anything else loaded) and ALL of the
  dataset's clinical columns in its order (`AppModel.tableColumns`). New file per export,
  named `T2_table_<dataset>_<n>samples_<k>columns_<time>.csv`; UI test checks the counts.
- **Samples section**: the dataset's presets are split by their rules into GROUPS (a rule with
  `in`: "GTEx normal tissues", "Primary tumors only"; alternatives, one at most, check-mark
  rows `group-<label>` plus `group-all`) and EXCLUSIONS (every rule `not in`: "Exclude cell
  lines", "Exclude tumors of heme origin"; switches `preset-<label>`). Each is offered only
  where it changes the sample set: a group that is empty within the data source or is the whole
  source is hidden, and so is an exclusion that would remove nothing, or everything, from the
  source and the chosen group (`AppModel.narrows`). An exclusion that stops being offered
  after a group change is switched off, so nothing hidden ever applies. Consequences: inside
  "GTEx normal tissues" no groups are offered and "Exclude cell lines" is gone (that part is
  normal tissue by definition: the 433 GTEx cell lines are not in it); inside "Primary tumors
  only" the "Tumor samples only" switch disappears. Nothing is hard-coded per dataset.
- **Service**: `ensureHemePreset()` adds the derived "Exclude tumors of heme origin" (the role
  map's heme values that exist as cohort levels) to a dataset whose `default_filters` table
  drops no cohort — Toil now has it (9 values: the leukaemias, DLBC, thymoma, GTEx whole blood,
  spleen, EBV lymphocytes, the CML line), so it is offered in the whole collection, the GTEx
  part and the TARGET part. Image `t2api:2026.10` redeployed (rollback `t2api:pre-heme-20261006`).
  The databases themselves were not touched.

### 2026-10-07 — Kruskal-Wallis removed, GTEx as a whole study, Y probes individually (Claude)

Nathan's notes on the night's round:

- **No test statistics on box plots** until real models exist: the Kruskal-Wallis line (and
  the per-panel `p =`) is gone from the plot and the figure. `Stats.kruskalWallis` stays in
  T2Kit, tested against R, for the model work. Scatter plots keep the correlation.
- **GTEx = the whole study.** The data sources for the parts of Toil are now presets defined
  in the app (`AppModel.subsetSources`, source "app"): GTEx = `study in GTEX` (7,862: the
  7,429 normal tissues AND the 433 EBV-transformed lymphocyte / cultured fibroblast samples
  the database calls "Cell Line" — the only cell lines in any of the databases), TARGET =
  `study in TARGET`. So "Exclude cell lines" is a real choice inside GTEx, as Nathan wanted.
  The database's "GTEx normal tissues" and "All normal tissue" presets come to exactly the
  same samples as that exclusion within GTEx, so they are not offered as groups there (a
  group identical to an offered exclusion yields to the exclusion). `default_filters.R` is
  unchanged: its presets are right as groups within the whole collection.
- **Plot Y probes individually** (the website's `multi_y`): `PlotRequest.yIndividually`;
  `PlotBuilder.stacked` makes one copy of every sample per Y probe with a categorical `probe`
  column and calls the ordinary builder on the stacked data, so box plots, scatter plots,
  facets, z-scores (per probe, over the samples in use), conditioning and the legend all
  work unchanged. No colour chosen → the colour is the probe (one box per probe per X
  category, as the website's colour menu switches to "probe"); a colour of the user's own →
  one graph per probe (and per "Graph for each" value: a combined `probe / facet` column).
  A Y probe that is also X, colour, size, graph variable or covariate is dropped from Y with
  a warning; at most 10 probes (T2_LIMITS$multi_y); the correlation line is dropped (a
  correlation over several genes' values at once means nothing); the sample summary is that of
  the real samples. The Select screen shows the switch under "Add to Y" whenever there is
  more than one Y; switching on remembers the colour and shows "Y probe" in the Color row,
  switching off gives it back (`setIndividualY`). Tests: two in PlotBuilderTests (values bit
  for bit, boxes per probe, panels per probe and per facet value, z-scores per probe), and
  test06 toggles it in the UI.

### 2026-10-07 — both databases rebuilt from scratch and verified; index benchmark (Claude)

Nathan: "run both tcga and tcgatargetgtex build pipelines, almost from scratch (omitting
downloads) and make sure everything works." Frozen clone `/scratch/nathan/R/T2-rebuild-20261007`
(main at 4b17c76), two containers at once (330/160 GB caps, peaks 51/48 GB), supervised and
verified by a Sonnet agent (`progress.md` in the clone has its line-per-milestone log).

- **Toil + DEMO**: 28.3 min + 1 min, exit 0/0. **TCGA**: the first run died after 54 min in
  `135-viral.R` — it read its table from the GDC URL on every build and GDC reset the
  connection. Fixed (4b17c76): the file lives in `TCGA/Data/viral_reads_gdc_a55229b3.tsv`
  like every other input; nothing is downloaded with `download = FALSE`. Restarted run:
  91 min, PROMOTED. Steps: rna 10.7 min, cnv 25.2, cnc 12.5, mut 5.3, final indexing 14.7,
  rest < 1 min (the master script now logs `==> STEP ... started/done`, dc630e6).
- **Verified, all three ready to serve**: rollback journal, no sidecars; SQL suites TCGA
  39/0/2 warn, Toil 35/0, DEMO 38/0; `sparse` 19 rows all matching the `tablemaker()` calls
  (rna/cnv/cnc/mut/viral/urna/rabit/hrd/muttest/tmb/estimate/msi sparse with default 0;
  rppa/pc_gene_program/immune_score/molec_subtype/immune_subtype/fmut/sig dense);
  `default_filters` 9/11/1 rows; `env_env` 44 vars, no secrets; duplicate barcodes averaged
  rna 9, rppa 10, viral 93, urna 6, pc_gene_program 8, immune_score 8, estimate 9;
  equivalence API vs gitr() ALL PASS (66/43/88 probes); **every table identical to the
  served 5 Oct files** except the build-metadata tables; `tcgai` per-type count/Σvalue/Σkeys
  identical for all 16 types; tcga.db the same byte count (40,875,065,344). The rebuilt
  files stay in the clone; nothing deployed (the served data are identical anyway).
- **Index benchmark** (`Util/index_bench.py`, bench copy of the new tcga.db, deleted after):
  56 statements — t2api's (probe by key per type), gitr's views (1–5 probes), 20/30/50/100-probe
  requests, whole-type pulls — cold (page cache evicted) and warm, with plans, then one index
  dropped at a time. Sizes: `tcgai` 15.5 GB, `tcgaiidx_pts` 15.8 GB, **`typeidx` 8.6 GB**,
  everything else < 1 GB. Every application statement uses the covering indexes; large
  requests scale linearly (tcgas 100 rna probes 3.4 s cold, API key batch of 100 0.84 s).
  `typeidx` was used by no application statement; it only served bare `WHERE type = X`
  admin queries. All of rna (195 M rows): via probe_types + covering index 151 s, via
  typeidx 163 s, full scan 216 s. Dropping it from a built file took 31 min (rollback journal).
  Small indexes: `probesidx`/`samplesidx`/`tested_type` are duplicates (3 MB each, no plan
  change), `clinpheno_tumtype_sample`, `tcgacatiidx_tsp`, `probe_types_tp` each earn their
  keep — Nathan: "don't worry about small indexes", so they all stay as they are.
- **Pipeline change (eee92e6, takes effect at the next build)**: `typeidx` no longer created
  (tcga.db 41 → ~32 GB); `tablemaker()` deletes a type's old rows only if the type was loaded
  before; new view **`bytype`** (probe_types CROSS JOIN tcgai, with names) for "all values of
  one type" or of one probe — rppa 2 s, rna ~150 s, CD8A 0.01 s; two plan tests in
  `sql_tests.R` (42/0 on the new tcga.db with the view added to a bench copy). README has a
  rebuild section and the view's usage. Nathan's wish for views so he need not hunt for the
  query: one view covers all types.
- Not done / for Nathan: rebuild tcga.db once more from the clone to materialise the smaller
  file (1.5 h) when convenient; the Mac was not needed this round.

#### Plan: group comparisons and linear models (discussed with Nathan 2026-10-06, not built)

The idea (Nathan): any filter can define a two-class problem, selected vs not selected; the
variables we mechanically "remove the influence of" are better treated as covariates in a
model; a decent modelling package with contrasts, not bare `lm`.

Proposed shape:

1. **One model specification** (T2Kit, `ModelSpec`, JSON-serialisable): response (the plotted
   Y, or the median z-score of Y + "Add to Y"); the **term of interest**: a filter marked
   "compare" on the Filter screen (group A = passes it, group B = does not; the universe is
   presets ∧ all OTHER filters, i.e. `mask(excluding:)`, samples with no value in that
   column are left out of both groups), or any categorical variable (X when categorical,
   sample_type, a `.mut`); **covariates**: cohort (on by default whenever the universe has
   more than one), the "Remove influences of" variables (on by default), any added variable,
   at most one interaction (term × covariate); **family** from the response: Gaussian for
   numeric Y, Cox for a survival endpoint (X is the endpoint, as the KM plot), binomial for a
   two-level categorical Y; the universe as a bit mask over the dataset's sample order plus
   the dataset `version` (19k samples = 2.4 KB; the server already shares the order).
2. **Where it runs**: an R model service (plumber, container beside t2api, Nginx `/api/t2m/`),
   built on the T2 R code so that the data are `gitr()`'s (same rule as the service), using
   `lm`/`glm`/`coxph` + `emmeans` (marginal means, pairwise or vs-reference contrasts, Holm
   or Tukey) + `car::Anova` (type II) + optional HC3 errors (`sandwich`) + `limma` for the
   genome-wide version. The same R function serves the Shiny site (a Model tab there) and the
   phone, so the two cannot disagree. A later on-device OLS (QR, treatment coding, emmeans-
   style contrasts) in T2Kit can give instant single-response answers; it would be validated
   against the service's R output anyway, so the service comes first.
3. **Results screen** (phone and site): adjusted means per group with 95% CI (dot-and-whisker,
   drawn by the existing scene code), contrasts (estimate, CI, p, adjusted p), ANOVA table,
   fit summary (n per group, R², residual SE; for Cox the hazard ratios, concordance), small
   residual-vs-fitted and QQ panels, warnings, a one-paragraph **methods sentence** and CSV
   export of the tables with the formula.
4. **Genome-wide group comparison** (the limma step, server only): "which variables differ
   between the groups?" with the same design (group + covariates), over the rna (and sig)
   probes, moderated t, Benjamini–Hochberg; a volcano plot and a top table; tapping a gene
   sets Y and draws it. This is the comparison the phone cannot do alone and the thing a
   two-class filter is really for.
5. **Guard rails in the spec, not the UI**: refuse a term that is the response or a covariate
   (a filter on CD8A compared on CD8A is circular); report aliased coefficients when the
   design is rank-deficient (GTEx-vs-TCGA with cohort as a covariate is perfectly confounded);
   minimum 3 samples per level, warn below 10; drop covariate levels that have no samples in
   the universe; cap pairwise contrasts (33 cohorts = 528 pairs → offer vs-reference or
   vs-grand-mean); Holm by default, Tukey for all-pairwise; cohort as a covariate is the
   default because tissue differences dominate every pan-cancer comparison.
6. **Order of work**: (a) `ModelSpec` + the Filter-screen "compare" mark + the Model screen
   skeleton; (b) the R function `t2_model(spec)` with equivalence tests (lm/emmeans/coxph
   outputs for fixed specs) and the plumber service; (c) results screen + CSV; (d) limma.

### 2026-10-07 — opening cohorts; first TestFlight build (Claude, with Nathan at the Apple sites)

**Opening cohorts.** Nathan: "in the default view (it is too busy right now), select cohorts
of COAD ESCA HNSC KIRC LUAD LUSC PAAD SKCM STAD". Per-dataset defaults belong to the service:
TCGA's `Defaults` gain `cohorts` (comma-separated; other databases: `dataset_meta.default_cohorts`),
documented in `docs/API.md`. The app (`AppModel.applyDefaultCohorts`, called from `open()`)
sets the cohort filter to those of them that exist, unless the user's own cohort choice is
carried over from the previous dataset; Toil's cohort names are long names, so a carried TCGA
choice does not narrow Toil. The opening plot shows 4,960 of 12,804 samples (4,094 plotted),
nine readable boxes. UI test03 compares the counts with the launch value instead of the
literal "12,804 of". Service redeployed with Nathan's "deploy" (the permission system asks for
production deploys; rollback tag `t2api:pre-cohorts-20261007`). Full Mac run green.

**TestFlight — what it took** (so nobody repeats the detours):
- Apple Developer Program approved 2026-10-07. Team ID, App Store Connect API key ids and
  the `.p8` live on the Mac in `~/.appstoreconnect/` (mode 600; `t2-testflight.env` is read
  by `ios/testflight.sh`); a reference copy of the identifiers is in `~/.config/t2/apple.env`
  on the Linux box. Nothing of it is in the repository — Nathan's rule.
- No certificates by hand: automatic signing makes them. **But** every `xcodebuild` attempt
  with a locked keychain creates an orphan Development certificate in the portal (key never
  stored) and the next attempt fails with "already has an Apple Development signing
  certificate for this machine, but its private key is not installed" → revoke the orphans
  on developer.apple.com > Certificates, and only ever run with the keychain unlocked.
- The login keychain is locked for an ssh session ("User interaction is not allowed").
  Nathan unlocks it himself, in **his own terminal**, in the same shell as the script:
  `security unlock-keychain ~/Library/Keychains/login.keychain-db && cd ~/Claude/T2Mobile && ./ios/testflight.sh`.
  Typing the password at a `!`-prefixed command in Claude Code went wrong twice (the prompt
  was interrupted and the keystrokes landed in the conversation) — don't do that.
- An archive is signed with a Development profile, which needs **at least one registered
  device**: the iPhone (UDID from `xcrun devicectl list devices` with the phone on the
  cable) was registered through the API (`~/.appstoreconnect/asc.py register`, a 60-line
  ES256-JWT client using only python3 + openssl).
- The export/upload needs cloud-managed **distribution** certificates, which an App Manager
  API key may not use ("Cloud signing permission error"): the key `t2-admin` has the Admin
  role. `testflight.sh --upload-only` reuses the archive of the last run.
- App record "T2 Cancer Genomics" (the name "T2" was taken; the name under the icon stays T2).
  Internal group "Internal" (`hasAccessToAllBuilds`) and the tester nosapple@fiveprime.org
  were created with the API; the build was "Ready to Test" on the phone ~15 min after upload.
- `asc.py` subcommands: `apps`, `builds APP`, `groups APP`, `mkgroup APP NAME`, `users`,
  `testers GROUP`, `addtester GROUP EMAIL`, `addbuild GROUP BUILD`, `devices`, `register NAME UDID`.

Next upload: bump `MARKETING_VERSION` in `Config/T2.xcconfig` when the version should
change (the build number is assigned by App Store Connect), rsync `ios/` to the Mac, Nathan
runs the unlock + `./ios/testflight.sh` line above; the Internal group sees the build as soon
as Apple has processed it.

### 2026-10-07 night — App Store listing, privacy, logging (Claude)

Nathan: "why not just release the app?" — agreed. Done through the App Store Connect API
(`~/.appstoreconnect/asc.py` on the Mac, Admin key): version 1.0 record (existed), subtitle,
description (3.4k chars, with the data citations Nathan asked for: TCGA Research Network
acknowledgement, Hoadley/Liu/Thorsson 2018, Vivian 2017 for Toil, TARGET phs000218, GTEx
Consortium 2013 + NIH Common Fund, Goldman 2020 for Xena), keywords, promotional text,
support/marketing/privacy URLs, copyright, categories **Medical** (primary; no "Science"
category exists — Nathan chose it) + Reference, age rating 4+ (all "NONE"/false), price free
(USD base), all 175 territories, seven 6.9" screenshots (1320×2868, from the UI tests on the
iPhone 18 Pro Max simulator; set type `APP_IPHONE_67` — the API has no `_69`). Everything is
in `docs/APPSTORE.md`; the App Privacy questionnaire has no API (instructions there).

Privacy, made true before it was written down:
- nginx: `access_log ... if=$t2api_failed` for `/api/t2/` — only 4xx/5xx (incl. rate-limit
  503s) are logged, with the address, so attacks stay visible; successful requests leave no
  record; nginx container logs rotate (json-file 5×20 MB). Deployed, verified (200 not
  logged, 404 logged). Nginx repo commits 7a01917, 2d78b99, fe78f89.
- t2api: the contact form no longer stores or logs the sender's address (`contactMessage.IP`
  removed; the per-address limit stays in memory). Deployed (`t2api:2026.10`, rollback
  `t2api:pre-noip-20261007`).
- `fiveprime.org/t2app/privacy.html` and `support.html` (with the citations) are served from
  the nginx image (`html/t2app/`, `location /t2app/`).

App (1.0 build): About → Attribution carries the citations; the no-connection screen says
"T2 is not available right now" with a polite explanation — phone offline vs. the service
not answering ("maintenance or a power cut at its home, try again in a little while") — the
technical error in small type below (`AppModel.lastError`, `outageText`). Nathan's request
"a polite message telling the user that the T2 API isn't running" is thereby in 1.0, not
only the next update.

**Submitted 2026-10-07 ~20:45 PDT**: Nathan answered App Privacy and the Medical category's
"regulated medical device: No" in the browser (both have no API) and uploaded build 1.0
(App Store Connect processed it in ~5 min); I attached the build, set release AFTER_APPROVAL,
created the App Review contact (phone/email his), `contentRightsDeclaration =
USES_THIRD_PARTY_CONTENT` (the public research data), then reviewSubmission →
reviewSubmissionItem → `submitted: true`. State: **WAITING_FOR_REVIEW**. Apple's mails go
to nosapple@fiveprime.org; a rejection comes with reasons — fix, new build, resubmit (the
same API steps with a new reviewSubmission). Nathalie installs from the App Store once it
is out (or: internal testing needs her to be a team user — Nathan's call).

### 2026-10-07 night — Failover: standby for the API (scouting, no decision yet)

Nathan: when the house loses power everything behind 99.132.144.201 is down, the app
included; wants a standby of `t2api` elsewhere, normally off, and a way to point the app at
it. Facts: image 15 MB; data 67 GB read-only (≈60 after the typeidx removal); 75 MB RSS,
idle CPU; fiveprime.org's DNS is at Cloudflare (TTL 300, not proxied). A Sonnet agent
scouted vendors → `docs/FAILOVER.md` (prices tagged by verification; several from memory); the recommendation, decisions and steps are in **`docs/FAILOVER-PLAN.md`**.
Claude's recommendation: **warm standby at Hetzner (≈ €8.5/mo, CX33 or CX23+volume)**
running t2api + nginx with its own Let's Encrypt cert (DNS-01 via Cloudflare API) and a
watchdog that flips the Cloudflare A record when home fails health checks and back when it
returns (3–7 min gap, no human). Cold + auto-start (Worker → vendor start API) saves ~$2/mo
at AWS/GCP only — not worth the complexity. Oracle Always Free would be $0 but reclaims
idle instances. R2 copy of the data ≈ $1/mo as a second copy. Open: gap acceptable vs
Cloudflare LB ($5+/mo, needs www proxied, Shiny sites included); Hetzner OK; go.

### 2026-10-09 — Simulator matrix: seven iPhones, light and dark (Claude)

Nathan: "run the testing suite on different iphone models in the simulator, also check on
dark mode"; permission to create simulators; and the rule above — nothing changes on `main`
while Apple reviews 1.0, work goes on branch `post-1.0`.

Script `ios/tools/sim_matrix.sh` (on the Mac, in `~/Claude/T2Mobile`; `ios/tools/` is not
rsynced, copy it by hand): one `build-for-testing`, then per device × appearance: boot, set
the appearance, `test-without-building` of T2UITests with retry, screenshots in
`screenshots/ui-<device>-<appearance>/`, verdicts in `logs/matrix/summary.txt`. Created the
iPhone SE (3rd generation) and iPhone 13 mini simulators (they share the installed runtime).
Lesson: xcodebuild does not see a simulator for the first seconds after `simctl create`
("Unable to find a device matching the provided destination specifier") and `simctl ui
appearance` fails on it too — the script now boots a new simulator once and waits.
Another: a script scp'd to the Mac needs `chmod +x`; a `nohup … &` inside ssh must be the
whole command, not the tail of an `&&` chain, or the ssh exit kills it.

Results (6 tests each, build 1.0 as submitted, against the live service; the three cells
first left out were run on Nathan's "proceed" the next morning — all green):

| device | light | dark |
|---|---|---|
| iPhone SE (3rd generation), 4.7" | green (after the test fix) | green (after the test fix) |
| iPhone 13 mini, 5.4" | green | green |
| iPhone 17e, 6.1" | green | green |
| iPhone 17 | green | green |
| iPhone Air, 6.5" | green | green |
| iPhone 18 Pro | green (10-07) | green |
| iPhone 18 Pro Max, 6.9" | green (10-07) | green |

The two SE failures were in the tests, not the app: on the 4.7" screen a List row read after
a scroll ("Primary tumors only" after choosing it; the exported file name after the second
export) had left the screen, and a SwiftUI List exposes only on-screen rows. Fixed by
`scrollTo` before the read (`T2UITests.swift`, test03 and test04). Dark mode, looked at on
the SE, Air and 18 Pro Max: Select, Filter, Plot, Publish, About and the outage screen all
render correctly; the figures keep their white background in both modes (publication
figures; intended). Observations, not bugs, for later: on the SE the plot's legend and the
survival risk table start under the floating tab bar (the list scrolls; by design); one Select
screenshot on the Air caught the glass tab bar refracting content mid-scroll (iOS 26 effect);
the count plot's subtitle says "Color: sample_type" though a count plot draws every circle
in one colour (small inconsistency, PlotScene subtitle).

Also verified at Nathan's request ("another instance could have modified the .sh scripts"):
the Mac's `ios/` is byte-identical to the repo (md5 over every .sh/.swift/.xcconfig/.yml/
.plist), no uncommitted tracked changes in the repo, no other logins on the Mac, the test
build linked today from sources newer than nothing (newest source 10-07), version 1.0 /
org.fiveprime.t2.

### 2026-10-09/10 night — Back-port: the app's features into the Shiny app, the service as the one source of dataset facts (Claude)

Nathan's request (evening): "back-port some of the features of the app back into the T2
shiny app": (1) make the Shiny app use the API, (2) the GTEx / TARGET subsets as data
sources, (3) other features of value; then, while I worked: reduce the duplication
between the two clients where a common API can; capture the app's "which filters make
sense for which data set" logic as one function, not spaghetti; stress-test the API
overnight for 100 (realistically) to 300 (aspirationally) users at a request every 10 s;
make sure the safeguards hold under a DDoS; build and tune a portable backup unit for a
small (4 GB) hosted machine, with notes on its configuration; the old `/T2` code base is
to be archived and the new one becomes production; run the API changes through an iOS
simulation; and (for later) an assessment of how monolithic the R files are. Everything on
`post-1.0`; nothing deployed.

**The service decides, the clients render.** `sources.go`: for each dataset `/meta.sources`
lists the whole collection and the parts it declares in `dataset_meta` (`source_col`,
`sources`, `source_labels`, `source_descriptions`; tcgatargetgtex: `study` → GTEx, TARGET),
each with its rules, sample count, the cohorts present (in `cohorts` table order), the
presets to offer as **groups** and as **exclusions** (a preset is offered only where it
keeps some but not all of the source's samples; a group identical to an offered exclusion
yields to it — the iPhone app's rule, now also computed on the server and consumed by the
R app; the app itself still applies the same rule on the phone, see the review below), and the
categorical clinical columns with a single value there. Presets carry `n_samples`.
`/probes?all=1` serves the whole menu list (1.7 MB TCGA, 0.6 MB gzipped, cacheable by
version). Go tests for the rules; `docs/API.md` has the new section. The `dataset_meta`
keys are written by the Toil builder from now on and by `dataset_meta.R set` for an
existing file; the served file lacks them until a database deploy (new directory;
`docs/PRODUCTION-SWITCH.md`). The auto-mode permission classifier refused my write to the
repository's development copy of the Toil database (a shared resource), so I made my own
copies: `/scratch/nathan/R/T2-devdata/` (README there; `tcga.db` a symlink, the two
datasets copied, the keys applied), which the development service
(`service/docker-compose.yml`) mounts and `T2_DATASETS_DIR` points the R tests at.

**The Shiny app** (`t2_presets.R` is the R mirror of the above for the SQLite path —
`t2_read_presets()`, `t2_sources()`, and `t2_filter_choices()`, the one place that decides
what the Select tab offers for a source and a chosen group; `test_equivalence.R` holds the
mirror equal to the service on every dataset): the Data set menu lists every collection and
its parts ("TCGA-TARGET-GTEx (Toil): GTEx"); the two hard-coded checkboxes are gone,
replaced by the database's presets (radio: one group at most; checkboxes: exclusions, each
only where it changes the samples of the source and the group); the sample choice reaches
`gitr()` as `rules` through `t2_sample_keep()` (plot, survival, Filter-tab universe, download
and Publish all agree, and the plot summary names it: "Samples: GTEx; Exclude cell lines");
a part restricts the Cohort menu, is never coloured or split by a single-level column,
gets its own Filter-tab instance whose categorical panels list only the levels present;
picks survive a data-source switch where the names exist (sticky selections); TCGA opens
on its nine default cohorts (`.TCGA_DEFAULTS$cohorts`, the service's value). `T2_DATASETS_DIR`
for tests. `test_app_sources.R` (26 checks); `test_app_thanos.R` updated (the switch test
now expects carried picks to get panels once the browser reports the repopulated
selectors); every other app test unchanged and green.

**Over the service** (`t2_api_client.R`, `T2_API_URL`): discovery, roles, the bundle
(`/meta`, `/probes?all=1`, `/clinical` once per version) and `gitr()` (`/values` in chunks
of 100, a per-process cache of 400 columns) have a second implementation; with the
variable set the app needs no database files (`con = NULL`, lib.R skips its legacy table
handles). `test_gitr_api.R`: frames identical to the files for clinical, probes of every
type, every filter, `keep_samples`, `rules`, `phenos = FALSE`, `makefactors = FALSE`, and the
bundle's lists; two by-design differences are documented in the test (column order of
factor-typed numeric probes — nothing reads by position; the service's menu adds the ten
clinical columns `allprobes` does not list). `service/test.sh shiny` runs it and the app
tests in the T2T image on the service's network: all pass (the app tests: 90 checks).
Latency, first request of 122 Toil probes: service 4.9 s, files 10.0 s; cached 0.13 s.
From the rstudio container the service is reachable only through the public URL (107 ms
per round trip vs 1.5 ms on the host): that is the remote-standby latency model Nathan
asked about — a plot of three probes costs three such round trips once, then the cache.
In production the Shiny containers share the service's Docker network
(`T2_API_URL=http://t2api:8080`, no TLS, no rate limits; `docs/PRODUCTION-SWITCH.md` step 3).

**Smaller features**: `t2_search.R` — the variable menus rank matches as the service does
(exact, prefix, contains; shorter first; `update_selectize_ranked()` replaces
`updateSelectizeInput(server = TRUE)` with a custom data handler); `t2_descriptions.R` —
what the clinical columns mean, read from the service's one TSV (or `/meta`), under the
Select tab for the chosen variables and as a table on About; `t2_contact.R` — "Contact the
author" on About, the app's POST path with the visitor's address forwarded (needs
`T2_CONTACT_URL`, or `T2_API_URL`); two categorical variables draw as counts (circles sized
by n with the number on each) instead of a box plot of a category.

**Stress tests** (`loadtest` gained `-think`, `-open`, `-insecure`; runs in
`/scratch/nathan/R/T2-devdata/stress_home.log`, against the development service with
production's limits, 8 CPUs / 4 GB, same files; production untouched):

| clients, a request every 10 s, half uncached probes | answered | median / p90 / p99 | memory |
|---|---|---|---|
| 100 (TCGA), each opening the app first | 10/s | 34 / 67 / 99 ms | 300 MB |
| 300 (TCGA) | 30/s | 10 / 50 / 71 ms | 465 MB |
| 300 (TCGA-TARGET-GTEx) | 30/s | 52 / 103 / 146 ms | 1.25 GB |
| **flood: 1,000 clients flat out, 80 % uncached** | 2,699/s; **844,263 refused (503) of 1,012,258 in 60 s** | 66 / 351 / 907 ms | 2.5 GB peak |
| 100 users right after the flood | 10/s, no errors | 6 / 8 / 9 ms | |

The refusals are the new `-max-inflight` cap (`limited` middleware: a request beyond the
cap is answered 503 with `Retry-After: 3` at once, `/healthz` exempt, `busy_refusals` in
`/statz`): a flood costs no memory and no disk time, and the users behind it are served.
The first runs had the cap at 64 and 16–243 of the "opening the app" bursts (100–300
phones fetching `/clinical` in the same second) were refused: the default is now 256
(256 × a 100-probe answer stays under 2 GB), the standby's 32. **DDoS review**: Nginx
already limits 50 requests/s and 60 connections per address (and the contact form 1/min);
what was missing was a bound on the service's own concurrency (now the cap) and, for the
standby, a *total* cap. A volumetric attack on the home uplink cannot be mitigated on the
host: only Cloudflare proxying would (FAILOVER-PLAN "Upgrade if the gap matters").

**The standby unit** `standby/` (README with the configuration notes Nathan asked for):
`docker-compose.yml` = t2api tuned down (`-cache-mb 128 -db-conns 8 -mem-limit-mb 640
-max-inflight 32`, 1.5 CPUs, 1 GB) + nginx (TLS; per-address 20/s burst 60 and 10
connections; a total cap of 200/s burst 400; short timeouts; small buffers; the down page
for every path that is not the API). Tried at home on other ports with my data copies and a
self-signed certificate: a dozen users 45 ms median; 100 users 35 ms (TCGA) / 68 ms
(Toil); a 500-client flood from one address: 1,629,972 refused by Nginx in a minute, the
users behind it at 7 ms median afterwards; service memory peaks ≈ 740 MB. Setup steps
(data copy, certificate by DNS-01, watchdog) in the README; the provider decision is still
Nathan's (`docs/FAILOVER-PLAN.md`).

**iOS**: the 1.0 app, unchanged, against the changed service — the UI suite accepts
`TEST_RUNNER_T2_SERVICE` (launch argument `-t2Service`, except for the test that names its
own unreachable address), the development service is tunnelled to the Mac
(`ssh -f -N -R 3861:127.0.0.1:3861 nathan@10.13.13.4`), `sim_matrix.sh "iPhone 18 Pro":light`.
Result: **all six tests passed** on the iPhone 18 Pro simulator, light (762 s, 66 screenshots;
`logs/matrix-api.out` on the Mac) — the 1.0 app works unchanged against the service with
`sources`, preset counts, `/probes?all=1` and the in-flight cap. (The first pass failed
test05 because my harness override replaced the test's own unreachable address; fixed in
the test, not the app.) Still to do on the app: read `meta.sources` instead of
`AppModel.subsetSources` (retiring the app-side definition; needs a Mac build and the UI
suite) — the service is backward compatible, so 1.0 needs nothing.

**Ideas noted, not done**: an R-datatype table in the databases (per column: R class,
level order) so any client can return the exact R structure — Nathan: "too big for now";
the `datatypes` table's `r_datatype` per type is the seed. `CODE-LAYOUT.md` (repository
root): the file index and the assessment of the monolithic files Nathan asked for.

### 2026-10-10 early hours — Chrome suite for the Shiny app, the app's parts from the service, the security pass (Claude)

Nathan's requests after the night's report: run the Shiny app through Chrome the way the
iPhone suite runs through the simulator and make that a test suite; proceed with the
teed-up steps except the code layout; then "harden Shiny and the API against advanced
exploit tools that seek to identify hidden functions and weaknesses by brute force"; the
contact form "must not be a vulnerability"; test execution goes to Sonnet subagents as a
standing principle (now in `~/.claude/CLAUDE.md`); a final code review by Fable at the end.

**Chrome suite** `test_browser_suite.R` (shinytest2 + the Chrome headless shell fetched into
`/scratch/nathan/R/T2-devdata/chrome/`): Select with the ready-made subsets, box / scatter /
survival / count plots, the GTEx part as data source (cohorts, Filter-tab universe, no
`study` panel, sticky picks), Publish, About with descriptions and the contact form; a
screenshot per step in `T2-devdata/screenshots/shiny-*/`. 27 checks on the files, 28 over
the service (`T2_API_URL`), both ALL PASS; the older `test_app_browser.R` (Filter tab, 53
checks) updated to the preset inputs and the nine default cohorts, passes. The page title
now names a part ("… — GTEx"). Run via a Sonnet agent from now on (the deploy script's
`check` step too: `T2_SITE_URL=https://www.fiveprime.org/T2/`).

**The app reads its parts from the service**: `/v1/datasets` entries carry `sources` as
`/meta` does; T2Kit `DataSource` (`DatasetSummary.parts`, `DatasetMeta.sources`, a decode
test; 58 tests); `AppModel.sources` / `allPresets` come from them and the app-side
`subsetSources` is gone — nothing about a dataset is written in the app any more. UI suite
on the iPhone 18 Pro simulator against the dev service: 6/6 (second run of the night after
the 1.0 app's own 6/6).

**Production steps** were refused by the auto-mode classifier ("Production Deploy": the
service redeploy and even writing the metadata keys into the NEW, unserved copy). They are
written up as commands in `docs/deploy-20261010.sh` (`service`, `data`, `code`, `api-mode`,
`nginx`, `archive`, `check`) for Nathan to run or allow. Done beforehand:
`/scratch/shinyusb/T2-data-20261010/` = a hard link to the unchanged `tcga.db` + copies of
the two datasets (the keys still to apply there, step `data`).

**Security pass** (dev instances only, never production). Two auditable harnesses instead
of a third-party scanner binary (the classifier refused the download, and these are
reviewable): `service/fuzz.sh` — hidden-endpoint discovery against two wordlists, every
HTTP method on every path, a battery of traversal / SQL / template / format-string / CRLF /
overflow payloads into every query parameter and the dataset path position, oversized
and repeated inputs, the contact endpoint, liveness and memory afterwards; invariants: no
undocumented path answers 2xx, only GET (POST on /contact) is accepted, no body leaks a
path, a Go stack or a SQL/driver string, caps hold, `/healthz` 200. `test_shiny_fuzz.R`
— the websocket input channel (a client can `Shiny.setInputValue` any name with any
value): server-only arguments (`keep_samples`, `rules`, `dbfile`, `roles`) set from the
client are ignored (12,804 samples, unchanged); unknown input names are inert; hostile
x / y / color / cohort values (SQL, R code, traversal, 5,000 chars, 500-name vectors) never
kill the session — `gitr()` binds every name as a SQL parameter, so a name is only a lookup
key; invented preset labels select nothing; out-of-range numbers, bad enums and invented
tweak ids are sanitised; invented Thanos columns are inert; no uncaught R error; a normal
plot draws afterwards. A Sonnet agent ran both to completion (API fuzzer 3 runs 6/6 each,
0 busy refusals, 163 MiB after ~2,400 hostile requests; Shiny fuzzer ALL PASS, 13 checks)
plus `test.sh abuse` (25 PASS; the 5 contact checks need a contact dir — they pass with
one, see below) and a code-reading pass (no `eval`/`system`/`get` on input, no SQL built
from input, no path from the dataset name, no `exec`; the offline build scripts
`tableget.R`/`sqlite_vacuum.R` use `paste`/`system` without user input). **Verdict: no
real findings; invariants hold.** One defence-in-depth change to the service: the probe
count cap is applied inside the parse loop (`handleValues`), so a request listing
thousands of names is refused before any list is built (bounded by the 16 KB header anyway).

**The contact form** (Nathan: "we don't want the contact functionality to be a
vulnerability"; "one good thing … those mail messages go to Unix mail"). Reviewed end to
end and verified empirically on the dev service with a scratch contact dir: a name of
`Bad\r\nBcc: victim@evil.com` is stored as `BadBcc: …` (CRLF stripped by `oneLine`); a
message with `\r\n` keeps only `\n` (`paragraphs`) and only ever lands in the mail body.
The host script re-validates the address, builds an ASCII-only subject, and delivers by
`sendmail -t` to loopback-only Postfix (`default_transport = local`): even a prevented
header injection could never make the form relay mail elsewhere. The one residual was the
readable `inbox.md`: stored markdown/HTML could render or forge the `## time` / `---`
structure in a viewer. Fixed in **version-controlled copies of the host scripts**,
`ops/contact/` (they lived only in `~/bin` before): the untrusted fields go inside a code
fence longer than any backtick run in them; every field re-sanitised; a failing MTA no
longer drops a message; `contact_fuzz.py` (offline, CommonMark-correct fence scanner)
proves no hostile message forges a heading or separator or escapes the fence. **Deploy to
`~/bin` is Nathan's** (`install -m 755 …`, README there). The dead "Client address" line
(the service never stores an address) is gone.

**Browser suite results in brief**: files 27/27, service 28/28, filter 53/53; API fuzzer
6/6 ×4; Shiny fuzzer 13/13; contact fuzz 6/6; abuse 30/30 with contact enabled; iOS 6/6 ×2;
T2Kit 58/58. Tools left running: `t2api-dev` (with `/scratch/nathan/R/T2-devdata/contact`
as a scratch contact dir, override file `t2api-dev-contact.yml` there). The Mac tunnel is
closed.

### 2026-10-10 — Final review by Fable, and the fixes (Claude)

Nathan asked for a final code review "with fable" (the session had dropped to Opus during
the security audit, which he noticed by the English). A fresh Fable agent reviewed the
whole branch (425927d..025e871, 49 files). Verdict: nothing changes served data (the
service, the SQLite mirror and the API client agree on every dataset, proven by the
equivalence tests); merge after seven should-fixes, all done the same hour:

1. **The R API client stuck on 409 after a database deploy** (the service restarts with a
   new version; the client read `/v1/datasets` once per process and kept the old version
   in every URL). Now a 409 forgets the datasets list and `t2_api_versioned()` asks again
   with the fresh version; caches are keyed by the version that answered. Also: a name the
   dataset lacks is remembered as missing (not re-requested on every plot), and a probe
   column becomes a factor only when its data type is declared "factor" in `datatypes`
   (gitr()'s rule; the type travels with each cached column as attr `t2type`).
2. **`deploy-20261010.sh` step `data` would have failed**: it wrote the metadata keys as uid
   999 into a copy owned by nathan (SQLite needs write on file and directory). Now it runs
   as the invoking user, chmods 644 and shows the keys back.
3. **Step `code` checked `post-1.0` out in the served tree**; the plan says merge to main
   first. Now it checks out `main` and calls `scripts/deploy.sh T2T`. Archive name unified
   (`T2.archive-20261010`).
4. **The forwarded address was spoofable**: both the R app and the service took the FIRST
   `X-Forwarded-For` entry, which the visitor controls (the live Nginx appends with
   `$proxy_add_x_forwarded_for` and also sets `X-Real-IP $remote_addr`; HAProxy adds
   nothing). Now both take `X-Real-IP` first, else the LAST forwarded entry; the R app
   forwards the visitor as `X-Real-IP`; and the Shiny contact form allows one message a
   minute per session (the container-to-container POST bypasses Nginx's per-address
   limit).
5. **Standby Nginx `proxy_buffering off`** let a slow-reading client hold a service
   in-flight token for a whole transfer (ten per address × four addresses = all 32
   tokens). Now buffered (32 × 32 KB, 16 MB temp): the service frees its token in
   milliseconds, the slow client costs Nginx a buffer. Config re-validated; a 2.6 MB
   `/clinical` through it in 26 ms.
6. **The exclusion checkboxes rebuilt themselves on every tick** (the renderer read
   `input$preset_excl` reactively), so a quick second tick could be lost. The widget now
   depends on the source and the group only; the ticks are read without a dependency.
   And the presets marked `on_by_default` are applied until the user chooses, as the app
   does (none is marked today).
7. The Shiny-fuzz log on disk was the first, halted run; the agent's passing log (13
   checks) is now `T2-devdata/shiny_fuzz.log`.

Nits taken: an all-NA text column is not categorical in the R mirror either (as
`sources.go`); the search handler caps a page at 500; `test_equivalence.R` compares preset
descriptions; the standby README says to `chmod -R a+rX` the data; `API.md` and this file no
longer claim the iPhone app consumes the service's group/exclusion lists (it still derives
them from the same rules on the phone — the three implementations agree; switching the
app to the lists is a follow-up). Noted, not changed: a part label containing `|` would
break the bundle key (metadata-controlled); the Thanos backends are keyed by path, not
version (a new session after a deploy); `t2_descriptions.R` reads the TSV relative to the
app directory; the app's `bundle()` keeps a dataset's presets until the next switch.
Behaviour changes the review lists as intentional, for Nathan to confirm on `/T2/`: TCGA
opens on nine cohorts; the two checkboxes are now the presets; the cohort menu lists only
cohorts present; two categoricals draw as counts; in API mode the menu gains ten clinical
columns and the CSV column order differs.

All suites were rerun by a Sonnet agent after the fixes — results appended below.

**Reruns after the fixes** (Sonnet agent; logs `*_after_review.log` in `T2-devdata/`):
service equivalence ALL PASS (25); gitr over the service ALL PASS (after one more fix: the
cached column's `t2type` attribute had leaked into the returned frame and made a text
column non-identical under `makefactors = FALSE` — the client now returns plain vectors);
app tests over the service no FAIL; file-mode test_app_sources 26, test_app_thanos 40,
test_app_server 6, all PASS; Chrome suite 28/28 on the files and 28/28 over the service;
Shiny fuzzer 13/13; API fuzzer 6/6 (541 requests, 0 busy refusals); abuse block 29/29
(contact enabled); contact_fuzz 7/7. `t2api-dev` healthy at 251 MiB afterwards.
