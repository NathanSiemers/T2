# When Apple answers on iOS 1.0 build 2: the release playbook for round 20261020

Written 2026-10-22 for a session that starts cold. Read `T2Mobile/NOTES.md` Status first, then this.

## Where things stand (2026-10-22)

- **With Apple:** iOS 1.0 **build 2** (build id 972d48a8, version record 1.0 id `20c097c4-ef8e-4c30-8519-f7f3894dfc4b`,
  reviewSubmission `635f739b-cb12-4e66-bacd-9f1f07d428e9`), WAITING_FOR_REVIEW since 2026-10-20 12:57 PDT. Tag
  `v1.0-build2-submitted` = 1ab06b7 on main. The 1.4.1 reply sits at the top of the version's App Review notes
  (appStoreReviewDetails `20a521bc-6abe-48cf-89ac-dcaed654b071`).
- **Production:** FROZEN by Nathan until he lifts it. Live: service `t2api` (+ `t2api-web`), data
  `/scratch/shinyusb/T2-data-20261020b`, code = main 6eb1c08 era, Nginx cache/limits bundle applied 2026-10-20.
- **Ready to ship:** PR #14 https://github.com/NathanSiemers/T2/pull/14 (branch `round-20261020`, head 15c9929, ready for
  review, all suites green at HEAD, see the PR comment). It carries the service (hidden datasets, `values?fill=`,
  usage metrics, go.sum-pinned build), the data-layer tooling, the web app items, **the iOS app at version 1.0,
  build counter 3** (`ios/Config/T2.xcconfig`: `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 3`; App Store
  Connect assigns the real build number itself), the listing texts for the next build (`docs/APPSTORE.md`), and
  `security/`.
- The iOS code in PR #14 works against the OLD service too (a values answer without `fill_options` means
  `["na"]`, the control stays hidden; `hidden` absent means not hidden), so the app build does not depend on the
  backend release order. But the reviewer should see the full feature: release the backend first.
- `/scratch/shinyusb/T2-data-20261021/` is a LEFTOVER staging directory from 2026-10-19 (dated ahead; never
  served; plain copies, not hard links, 77 GB). Not Nathan's intent to serve it. Use a later date for the new
  stage (`data-stage` refuses an existing directory) and delete the leftover when convenient (Nathan's call; it is
  under a served path, so Claude does not remove it unasked).
- The Mac (`nathan@10.0.0.110`) timed out on ssh at 2026-10-22 early hours (asleep or on the VPN address
  10.13.13.4). `T2_MAC=<address> ops/test.sh ios` takes the address.

## Step 0: find out what Apple said (read-only, from the Mac)

    ssh nathan@10.0.0.110 '~/.appstoreconnect/asc.py get reviewSubmissions/635f739b-cb12-4e66-bacd-9f1f07d428e9'
    ssh nathan@10.0.0.110 '~/.appstoreconnect/asc.py get appStoreVersions/20c097c4-ef8e-4c30-8519-f7f3894dfc4b'

States: `WAITING_FOR_REVIEW` / `IN_REVIEW` = still pending (do nothing, freeze holds); `COMPLETE` with the version
`READY_FOR_SALE` or `PROCESSING_FOR_DISTRIBUTION` = approved; `UNRESOLVED_ISSUES` / version `REJECTED` = rejected
(message in the Resolution Center; Nathan pastes it). Nathan lifts the freeze explicitly; that sentence is the
start signal for everything below.

## Path A: APPROVED (1.0 build 2 is live)

1. **Record it**: date and state in `NOTES.md` Status; the App Store listing shows the build-2 texts (the old
   collection list; that is expected, the new texts go in with the next version).
2. **Merge PR #14** (`gh pr merge 14 --merge`, or Nathan in the browser), `git checkout main && git pull`.
   Run `security/scan.sh --quick` on main; Nathan accepts the baseline (`security/scan.sh --baseline`) after
   reading `git diff security/`; commit the baseline.
3. **Backend release, RELEASE.md order, Nathan runs or Claude with the deploy.sh allow rule** (say what each step
   does first; every step is safe alone):
   1. `T2Mobile/ops/deploy.sh service` (new Go image; prints the rollback tag).
   2. Data. The checkout's `datasets/` files are hard links of the dev files, which already carry
      `types.fill_options` (cptac) and `hidden=1` (DEMO) and pass `dataset_contract_check.R`. Verify before staging:
      `sqlite3 -readonly datasets/cptac.db "select type,fill_options from types where fill_options!='na'"` (prot,
      phospho = `na|zero|floor`) and `sqlite3 -readonly datasets/DEMO.db "select value from dataset_meta where key='hidden'"`
      (1); `ls -i datasets/cptac.db /scratch/nathan/R/T2-devdata/datasets/cptac.db` (same inode). Then
      `deploy.sh data-stage <YYYYMMDD> cptac.db DEMO.db` (TCGA and Toil stay hard links of the served files),
      `deploy.sh data /scratch/shinyusb/T2-data-<YYYYMMDD>`.
   3. `deploy.sh code` (the web app items), `deploy.sh status`, `deploy.sh check`.
   4. Live checks: `curl -s https://www.fiveprime.org/api/t2/v1/datasets` (DEMO hidden true),
      `.../v1/cptac/values?probes=CLDN6.prot&fill=zero` (fill, filled), the website shows "Not-detected values"
      only with a `.prot`/`.phospho` variable; `ops/test.sh browser-live`.
   5. Website blurb in `/scratch/Docker/Nginx/html` ("TCGA (The Cancer Genome Atlas) and other genomic
      databases"): edit the html, `deploy.sh nginx` is NOT needed for html (bind mount) unless the config changed.
4. **iOS 1.1**: on main set `MARKETING_VERSION = 1.1` in `T2Mobile/ios/Config/T2.xcconfig` (keep
   `CURRENT_PROJECT_VERSION = 3`; ASC numbers the build), update "What's New (1.1)" in `docs/APPSTORE.md` (the
   not-detected option, the "Filtered:" caption, Publish text switches, the survival hint, hidden demo data, the
   source part in the title), commit.
   - Simulator against the DEV service: `T2_MAC=10.0.0.110 T2Mobile/ops/test.sh ios` (rsyncs `ios/`, 8 unit +
     9 UI expected).
   - Simulator against the LIVE service (the pre-upload check): `ssh nathan@10.0.0.110 'cd ~/Claude/T2Mobile &&
     ./ios/tools/sim_matrix.sh "iPhone 18 Pro":light'` (no `TEST_RUNNER_T2_SERVICE` = the app's default
     https://www.fiveprime.org/api/t2). Test09 needs the live cptac.db with `fill_options`, so run it after step 3.
   - Upload: Nathan unlocks the keychain in HIS terminal on the Mac
     (`security unlock-keychain ~/Library/Keychains/login.keychain-db`), then `~/Claude/T2Mobile/ios/testflight.sh`
     (Claude may run it over ssh after the unlock, per Nathan's 2026-10-20 authorization). Wait until
     `asc.py builds <APP>` shows the new build VALID (processing takes 5-15 min).
   - App Store Connect (`asc.py`; generic verbs `get`, `post`, `patch`, `patchrel`; the classifier may refuse writes
     to Claude, then Nathan runs the lines): `post appStoreVersions` for 1.1 on app 6820327009 (platform IOS,
     versionString "1.1"); `patchrel` the build onto the version; `patch appStoreVersionLocalizations` of the new
     version with the texts of `docs/APPSTORE.md` (promotional text, description, keywords, what's new; subtitle
     is on the app info localization); App Review notes (the research-use statement and where the citations are,
     as for build 2); `post reviewSubmissions` (app, platform IOS) + `post reviewSubmissionItems` (the version) +
     `patch reviewSubmissions ID {"submitted": true}`. Verify with `get`.
   - Tag `v1.1-submitted` on the commit built; `NOTES.md` Status; memory `apple-review-outcome`.
5. Invite Nathalie to TestFlight / the App Store (open item since before the 1.0 submission).

## Path B: REJECTED again

1. Nathan pastes the message. Decide with him: (a) a listing/metadata answer (no build: patch the texts or reply),
   (b) the round's code is the answer, (c) a small extra fix on top of the round.
2. **Reply in the Resolution Center thread FIRST** (lesson of 2026-10-20: canceling the submission kills the thread;
   a fresh submission has no Reply button). If Apple allows resubmitting the same submission after a reply, prefer
   that over cancel + new.
3. Code path: Path A steps 2-3 unchanged (merge, backend release). iOS: **marketing version stays 1.0**, the build is
   "build 3" (ASC numbers it); reuse version record 1.0 (`20c097c4-…`): after the upload, `patchrel` the new build
   onto it (the rejected build is replaced), update the App Review notes with the answer to the new objection, and
   either resubmit the existing submission or cancel it (`patch reviewSubmissions ID {"canceled": true}`) and
   create a new one with the version as its item. Listing texts of `docs/APPSTORE.md` may go in now (editable on a
   rejected version). Tag `v1.0-build3-submitted`.
4. Same tests as Path A step 4 before the upload (dev run, then live run).

## Hard rules in force

- Never upload a build or write to ASC while a submission is pending. Never type a password at a `!` prompt.
- Never write to `/scratch/shinyusb` or `/scratch/Docker` except through `deploy.sh` steps; data releases are new
  staged directories, never edits of a served file.
- The freeze ends only when Nathan says so; until then the answer to "Apple replied" is Step 0 and a report.
