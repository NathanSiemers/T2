# The iPhone app — design, state, and what you need to do

## Design in one paragraph

The app is T2T with the work moved onto the phone. It asks the server (t2api, docs/API.md)
for columns of numbers and does everything else itself: applying the dataset's ready-made
subsets, cross-filtering (the Thanos screen), statistics, drawing, and making figures. One
gene is ~13,000 numbers (24 KB gzipped); a phone filters and draws that instantly, and
nothing the user does after the data arrives costs the server anything.

## What exists (2026-10-04)

| Part | Where | State |
|---|---|---|
| **T2Kit** — models, API client, presets, cross-filter, statistics | `ios/T2Kit` (Swift package, no UI code) | **Built and tested** on Linux with Swift 6: 12 unit tests pass; statistics agree with R (quantiles, lm, Kaplan-Meier, log-rank) to 1e-9 or better |
| **t2smoke** — command-line client | `ios/T2Kit/Sources/t2smoke` | **Run against the live service**: all three datasets, presets, search, filtering, regression: all pass |
| **The app** — SwiftUI screens | `ios/T2App/Sources` (5 files, ~600 lines) | **Written, syntax-checked, NOT compiled** (no Xcode here). Expect a handful of small fixes on first build. |

Screens, mirroring the website's tabs:

- **Select**: dataset, X / Y / Color (type to search the dataset's 135,650 variables; the
  server does the search), the dataset's presets as switches ("GTEx normal tissues", ...).
- **Plot**: scatter with fit line when X is numeric; boxes with jittered points when X is
  categorical; n, r and slope underneath; point size, transparency, font sizes, legend.
- **Filter**: Thanos. One card per variable: histogram of the samples passing all *other*
  filters with this variable's selection highlighted, a range (two sliders; a handle at its
  end means no limit) or level switches, "include missing". Plotted variables are added
  automatically; any other can be added.
- **Publish**: width and height in inches, resolution, presets (half page x 1/3 page, full
  page x half page, Nature single column, slide), print-scale sizes kept separately from the
  screen's, live preview, export PNG or vector PDF, share sheet. Removing the source line
  shows the citation reminder.

One drawing routine (`PlotCanvas`) serves the screen, the preview and the exported file, so
the preview is the figure: the file is the same view at `dpi / 72` pixels per point.

### Not built yet

- Survival (Kaplan-Meier) *screen*: the estimator and log-rank test are in T2Kit and
  tested; drawing the curves and risk table is not written.
- Size-by-variable, facets ("graph for each"), conditioning ("remove influences of"),
  multi-probe X/Y (the median-z combination IS in T2Kit: `Stats.combineMedianZ`).
- TIFF export (ImageIO; small), the full list of ggplot-style settings.
- Keeping fetched columns on the device between launches (the API is designed for it:
  every dataset has a `version`, responses carry ETags).
- Numeric colour scales (colour is categorical only), density for very large scatters.

## What you need to do

1. **On the Mac** (Xcode 15 or newer; nothing to pay):

       brew install xcodegen
       # copy or clone /scratch/nathan/R/T2/T2Mobile to the Mac, then:
       cd T2Mobile/ios/T2App && xcodegen && open T2.xcodeproj

   Choose an iPhone simulator and Run. (Without XcodeGen: new iOS App project in Xcode,
   add the files in `Sources/`, add `../T2Kit` as a local package.)
2. **Send Claude the build errors**, if any (copy the Issue navigator's text). The screens
   were written without a compiler; fixing them is quick once the errors are visible.
3. **Let the app reach the service.** The service is not public. For development, tunnel:

       ssh -L 3860:127.0.0.1:3860 <this server>

   and leave the app's "Service address" (Select tab) at `http://localhost:3860`. The
   simulator shares the Mac's network, so that works as is.
4. **To run on your own iPhone**: sign in to Xcode with any Apple ID (free), select your
   phone, Run. Free signing lasts 7 days per install. The phone must reach the service: on
   the same network as a machine running the tunnel with `-g`, or once the service is
   published over https.
5. **For TestFlight or the App Store**: the Apple Developer Program ($99/year), an app
   name, an icon, a privacy statement (the app collects nothing; it reads public data), and
   the service published at an https address. Apple review usually takes a day or two.

## Decisions for you

- **Publish the service?** The app needs an https address outside development. Suggested:
  `https://www.fiveprime.org/api/t2/` through the existing Nginx.
- **App name and bundle id** (placeholders: "T2", `org.fiveprime.t2`).
- **iPad?** The screens will run on iPad as they are; a proper iPad layout (plot and
  filters side by side) is a natural follow-up.
