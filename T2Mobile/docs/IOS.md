# The iPhone app — design, state, and what you need to do

Last updated 2026-10-05 (branch `t2mobile-ci`). The log in `../NOTES.md` has the history.

## On the Mac: one command

    /path/to/T2/T2Mobile/ios/mac_setup.sh

(the T2 repository as mounted from the Linux server, or a clone of branch `t2mobile-ci`).
It needs Xcode 15 or newer from the App Store and nothing else: no Homebrew, no Apple
Developer membership, no sudo. It is safe to run again at any time. What it does:

1. checks macOS, Xcode and the iOS Simulator, and says exactly what to do if one is missing
   (it downloads the iOS Simulator itself if Xcode has none);
2. copies `T2Mobile/ios` to a local folder, `~/T2Mobile/ios` (never builds on a network
   mount; a re-run copies only what changed and keeps your signing settings);
3. gets XcodeGen (an installed one or Homebrew if present, otherwise the official release
   binary into `~/T2Mobile/tools`) and generates `T2.xcodeproj`;
4. runs the T2Kit unit tests;
5. builds the app for the iOS Simulator;
6. boots a simulator, installs and starts the app, saves screenshots of its four tabs to
   `~/T2Mobile/screenshots`;
7. opens the project in Xcode and prints the next steps (your own iPhone with a free Apple
   ID; what changes with the paid membership).

Options (`mac_setup.sh --help`): `--dest DIR`, `--device "iPhone 17 Pro"`, `--dark`,
`--ui-tests` (drive the app through its flows, a screenshot per step), `--team ID`,
`--bundle-id ID`, `--no-brew`, `--no-open`, `--ci`. Its output is also in
`~/T2Mobile/mac_setup.log`; each long step has its own log in `~/T2Mobile/logs`.

If it fails it stops with `FAILED in step N/7 (...)`, the compiler or test errors, and the
log to read. Send that text to Claude.

## How it is known to work: CI on real Macs

There is no Mac on the development host, so the app meets Xcode on GitHub's macOS runners:
`.github/workflows/t2mobile-ios.yml` runs **the same `mac_setup.sh`** for every push to the
branch `t2mobile-ci` (free for a public repository; no secrets).

- Runner image `macos-26` (arm64, macOS 26.6.2), **Xcode 26.6 (17F113), iOS SDK 26.5**,
  iOS 26.5 simulators; XcodeGen 2.46.0 (downloaded by the script).
- Job `mac-setup`: the script on a clean machine, XcodeGen by download (`--no-brew`). It
  also runs on `macos-15` (Xcode 16.4, iOS SDK 18.5) for information: that job's result
  does not decide the run.
- Jobs `ui-tests` (three: iPhone 17 Pro Max light, iPhone 17 Pro dark, iPhone SE 3rd
  generation light, a simulator the script creates; the SE job takes the Homebrew route to
  XcodeGen): the script with `--ui-tests`, six flows. The screenshots are artifacts of the
  run: `gh run download <run id> -D somewhere`.
- To see a run: https://github.com/NathanSiemers/T2/actions (workflow "T2Mobile iOS").

The branch `t2mobile-ci` is built on the published `main` and carries only
`T2Mobile/ios`, `T2Mobile/NOTES.md`, this file and the workflow (the query service and the
database changes were not published by it).

## Design in one paragraph

The app is T2T with the work moved onto the phone. It asks the server (t2api, docs/API.md)
for columns of numbers and does everything else itself: applying the dataset's ready-made
subsets, cross-filtering (the Thanos screen), statistics, drawing, and making figures. One
gene is ~13,000 numbers (24 KB gzipped); a phone filters and draws that instantly, and
nothing the user does after the data arrives costs the server anything. The service is
public: `https://www.fiveprime.org/api/t2` (the app's default; changeable on the Select tab).

## Parts

| Part | Where | State |
|---|---|---|
| **T2Kit** — models, API client, presets, cross-filter, statistics, palette, plot builder | `ios/T2Kit` (Swift package, no UI code) | see "State" below |
| **The app** — SwiftUI screens | `ios/T2App/Sources` | see "State" below |
| **UI tests** | `ios/T2App/UITests` | see "State" below |
| Project description | `ios/T2App/project.yml` (XcodeGen), `ios/T2App/Config/T2.xcconfig` | bundle id `org.fiveprime.t2`, display name T2, version 0.2.0 (1), iOS 17.0+, iPhone, portrait + landscape |
| Icon, launch screen | `ios/T2App/Resources/Assets.xcassets`; drawn by `ios/tools/make_icon.py` | generated, committed |

`T2.xcodeproj` and `Info.plist` are generated (not in git): change `project.yml` or
`Config/T2.xcconfig`, not Xcode's build settings. One Mac's own settings (team, another
bundle id) go in `Config/Local.xcconfig`, which the script writes (`--team`, `--bundle-id`)
and keeps; a team chosen in Xcode's Signing & Capabilities is carried over on the next run.

### T2Kit (everything numerical; tested on Linux and macOS)

- `Models`, `APIClient`: the service's JSON; `DatasetMeta.usableSurvivalEndpoints` (the
  service lists OS/PFI/DSS/DFI for every dataset; only TCGA has the columns).
- `Filtering`: presets and the Thanos cross-filter (leave-one-out histograms).
- `Stats`, `StatsMore`: quantiles, box statistics, regression, Pearson and Spearman with
  p-values, Kruskal-Wallis, Kaplan-Meier with Greenwood confidence limits, log-rank, Cox
  (one covariate, Efron ties), quantile groups as `survival_km()` makes them, residuals
  ("remove influences of"), median-z combination. Reference values from R 4.5.3 /
  survival 3.8.6 are in the tests.
- `Palette`: viridis plasma (as the website), the survival colours.
- `PlotScene`, `PlotBuilder`, `PlotBuilderSurvival`: a plot worked out as data (panels,
  axes, points, boxes, lines, bands, count circles, risk table, legend, statistics, sample
  counts) from the user's choices, following `lib.R`'s `fun_plot1()` and
  `survival_prototype.R`'s `survival_km()` step by step. The tests include: every plotted
  x and y is bit for bit the value the service sent.
- `TableExport`: the table behind a plot as CSV (numbers that read back exactly, NA).
- 52 tests; they pass on Linux (Swift 6.0) and on macOS (Xcode 26.6 and 16.4).

Run the tests on Linux:

    cd T2Mobile/ios/T2Kit
    docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -v "$PWD":/pkg -w /pkg swift:6.0-jammy swift test

## State

Three levels of "works" are kept apart here. The log in NOTES.md says which CI run showed what.

### What the app does

| Screen | Function | Website equivalent |
|---|---|---|
| **Select** | dataset (menu); X, Y, Color, Size, "Graph for each" (search as you type: the server searches the 135,650 names; clinical columns are offered before typing); Cohorts (multi-select with long names); the dataset's presets as switches (from `meta.presets`: "Tumor samples only", "GTEx normal tissues", ...); more variables on X or Y (combined as median z-score); "Remove influences of" (X / Y / both); service address | Select tab |
| **Plot** | scatter with fit line (two numbers); boxes with jittered points (category against number, either way round); counts as circles (two categories); Kaplan-Meier curves with confidence bands, medians, numbers at risk, log-rank p, Cox HR per SD (a survival endpoint on X; groups 2-6, follow-up limit); one graph per level; colour by category or number, size by number; z-score Y, flip, waterfall; statistics (n, Pearson and Spearman with p, fit line, Kruskal-Wallis p); the website's sample-count summary; notes when an option cannot apply; point size, transparency, font sizes, legend, source line; the table behind the plot as CSV | Plot + Appearance tabs, Download Table |
| **Filter** | Thanos: one card per variable (plotted ones are there from the start, any other can be added): numeric = histogram with a from/to range, categorical = levels as bars that are the checkboxes (All / None), "include samples with no value"; every bar shows the samples passing all OTHER filters; live counts | Filter tab |
| **Publish** | the figure at its physical size, preview = the file; sizes from the website's presets (half page x 1/3 page, full width x half page on US letter with 0.75 in margins, Nature single / double column, slide), width / height / dpi, print-scale font sizes kept apart from the screen's; PNG and TIFF (LZW) with the resolution recorded in the file, vector PDF; share sheet; the citation line (with a reminder if it is switched off) | Publish tab |

Problems are said in words: no connection ("Cannot reach T2", Try again), a variable the
dataset does not have, a search without matches, no sample passing the filters (with
"Remove all filters"), too few samples or too few distinct values for survival groups.

### How far each part has been checked

- **Compiled with Xcode 26.6 and seen working in simulator screenshots** (CI run
  37278262683, commit 9bfc855, all jobs green; iPhone 17 Pro Max, iPhone 17 Pro in dark
  mode, iPhone SE 3rd generation; 46 screenshots per device, looked at by Claude on the SE
  and partly in dark mode): dataset menu and all three datasets; gene / mutation / clinical
  search and the no-match message; default box plot (11,005 points for TCGA cohort x CD8A,
  the number computed from the API beforehand); scatter with fit line and statistics;
  numeric colour and size; boxes by gender and by TP53.mut; presets (TCGA's five, and
  tcgatargetgtex's "GTEx normal tissues" etc. from the database); the Filter screen with
  live counts down to no samples and back; Publish with both page presets, PNG and PDF
  export and the share sheet showing the PDF; survival by CD8A tertiles and by TP53.mut;
  one graph per gender; counts for gender x TP53.mut; the Cohorts chooser; the CSV table
  being made; unknown probe; no connection.
- **Compiled with Xcode 26.6 and exercised by passing UI tests, screenshots not looked at**
  (CI run 37306211658, commit 1d12154, on iPhone SE and iPhone 17 Pro dark): TIFF export
  (the test checks the app reports a TIFF file), "Add to Y" + "Remove influences of" (the
  test picks CD8B and PTPRC and opens the plot). On the iPhone 17 Pro Max the Publish flow
  of that run failed because the test tapped a button lying under the tab bar (a test
  problem; NOTES.md has the details), so that run as a whole is red.
- **Not opened or verified**: the exported PNG / TIFF / PDF / CSV files themselves (their
  pixel size, recorded dpi, vector content); landscape; Dynamic Type sizes; a real iPhone.
- **Xcode 16.4** (runner macos-15, job for information only): T2Kit's 52 tests pass and the
  project generates; the app build failed on one expression Xcode 16 could not type-check
  (`AppModel.writeTable`), since rewritten. Whether the rest builds with Xcode 16 is shown
  by the newest run's macos-15 job (see NOTES.md). Use a current Xcode if you can.

Known cosmetic flaws seen in the screenshots and left: in small "graph for each" panels
the per-panel note (n, r) overlaps the points; the coloured dots of the numbers-at-risk
table touch the first number; a survival plot's legend sits under the tab bar until the
page is scrolled; the 93 cohort labels of tcgatargetgtex are thinned out and shortened.

### Deliberate differences from the website

- A **categorical marker in a survival plot** (TP53.mut, gender) is stratified by its own
  levels. The website turns it into numbers and cuts tertiles, which a 0/1 marker cannot give.
- Box plots coloured by a category draw one box per X level with coloured points; the
  website draws one box per colour within each X level (dodged).
- The fit line has no confidence band and there is no dashed median-regression line.
- Statistics the website does not print are shown (correlations with p, Kruskal-Wallis).
- Colours: the plasma map from 33 anchors (within 1% of viridis).

### Not built (explicit gaps)

- "Plot Y probes individually" (multi-Y facets); faceted survival grids; non-numeric
  covariates in "Remove influences of".
- The Appearance tab's registry of ~440 ggplot settings, axis transforms (log), font
  choice, units other than inches on Publish.
- The About tab (data-type table with references).
- Keeping data on the device between launches (the API is ready for it: `version`, ETags).
  Every launch downloads the clinical table again (0.5 MB gzipped for TCGA).
- iPad layout; tapping a point to see which sample it is; landscape-specific layouts.
- Performance tuning: the scene is rebuilt whenever a screen redraws (fine in the
  simulator with 19,131 samples; not measured on a phone).

## Your own iPhone, TestFlight

`mac_setup.sh` prints these steps at the end; in short:

- **Free Apple ID ("Personal Team")**: Xcode > Settings > Accounts > add your Apple ID; in
  the project, target T2 > Signing & Capabilities > Team = your Personal Team; connect the
  phone, enable Developer Mode on it (Settings > Privacy & Security), Run; the first time,
  trust the developer on the phone (Settings > General > VPN & Device Management). The app
  stops opening after 7 days: Run again.
- **With the Apple Developer Program** ($99/year): `mac_setup.sh --team YOURTEAMID`; create
  the app in App Store Connect with the bundle id; Product > Archive > Distribute >
  TestFlight. Raise `CURRENT_PROJECT_VERSION` in `Config/T2.xcconfig` for every upload.
  For the App Store: screenshots, a privacy policy address, privacy answers ("Data Not
  Collected": the app only reads public data).

## Decisions for you

- **App name and bundle id** (now "T2", `org.fiveprime.t2`; the bundle id is fixed after
  the first upload to App Store Connect).
- **iPad**: the app is iPhone-only for now (an iPad runs it in iPhone mode); a proper iPad
  layout (plot and filters side by side) is a natural follow-up.
