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
- Job `mac-setup`: the script on a clean machine, XcodeGen by download (`--no-brew`).
- Jobs `ui-tests` (three: iPhone 17 Pro Max light, iPhone 17 Pro dark, iPhone SE 3rd
  generation light): the script with `--ui-tests`. The screenshots are artifacts of the run:
  `gh run download <run id> -D somewhere`.
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
- `PlotScene`, `PlotBuilder`: a plot worked out as data (panels, axes, points, boxes,
  lines, legend, statistics, sample counts) from the user's choices, following `lib.R`'s
  `fun_plot1()` step by step. The tests include: every plotted x and y is bit for bit the
  value the service sent.

Run the tests on Linux:

    cd T2Mobile/ios/T2Kit
    docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -v "$PWD":/pkg -w /pkg swift:6.0-jammy swift test

## State

(updated at each milestone; see the newest entry of the log in NOTES.md)

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
