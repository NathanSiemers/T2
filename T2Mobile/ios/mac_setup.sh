#!/bin/bash
# mac_setup.sh -- build and run the T2 iPhone app on a Mac, from a fresh checkout or a
# network mount, without an Apple Developer membership.
#
#     /path/to/T2Mobile/ios/mac_setup.sh            # everything; safe to run again
#     /path/to/T2Mobile/ios/mac_setup.sh --help
#
# What it does, in order:
#   1. checks macOS, Xcode and the iOS Simulator, and says what to do if one is missing
#   2. copies the sources to a LOCAL folder (default ~/T2Mobile; never builds on a mount)
#   3. gets XcodeGen (Homebrew if you have it, otherwise the official release binary,
#      kept inside the local folder) and generates T2.xcodeproj
#   4. runs the T2Kit unit tests (filtering, statistics, plot geometry)
#   5. builds the app for the iOS Simulator
#   6. boots a simulator, installs and starts the app, saves screenshots
#   7. opens the project in Xcode and prints what to do next (your own iPhone; TestFlight)
#
# No sudo, nothing installed outside the local folder (except `brew install xcodegen` when
# Homebrew is present). The same script runs in CI on GitHub's macOS machines
# (.github/workflows/t2mobile-ios.yml), which is how it is known to work.
#
# Written for the bash 3.2 that macOS ships: no associative arrays, no mapfile.
set -euo pipefail
set -E

usage() {
    cat <<'EOF'
Usage: mac_setup.sh [options]

  --dest DIR        local working folder (default: ~/T2Mobile, or $T2_DEST)
  --device NAME     simulator to use, e.g. "iPhone 17 Pro" or "iPhone SE (3rd generation)"
                    (default: a booted iPhone, else a recent iPhone that is installed)
  --dark            put the simulator in dark mode (default: light)
  --team ID         your Apple developer Team ID (10 characters); remembered in
                    T2App/Config/Local.xcconfig in the local folder
  --bundle-id ID    another bundle identifier than org.fiveprime.t2; remembered likewise
  --ui-tests        also run the UI tests (they drive the app through its main flows
                    against the live service and save a screenshot of every step)
  --no-brew         do not use Homebrew or an installed xcodegen: download XcodeGen
  --no-open         do not open Xcode or the Simulator window at the end
  --ci              for unattended machines: implies --no-open, longer timeouts
  -h, --help        this text

Everything it writes goes to the working folder:
  ios/            the copied sources and the generated T2.xcodeproj
  build/          Xcode's build products
  tools/          XcodeGen, if it had to be downloaded
  screenshots/    what the app looked like in the simulator
  logs/           full output of each step;  mac_setup.log = this script's own output
EOF
}

# ------------------------------------------------------------------ arguments
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${T2_DEST:-$HOME/T2Mobile}"
CI=0; USE_BREW=1; OPEN_UI=1; RUN_UI_TESTS=0
DEVICE=""; APPEARANCE="light"; TEAM=""; BUNDLE_ID=""
need_value() { [ $# -ge 2 ] || { echo "mac_setup.sh: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)      need_value "$@"; DEST="$2"; shift 2 ;;
        --device)    need_value "$@"; DEVICE="$2"; shift 2 ;;
        --team)      need_value "$@"; TEAM="$2"; shift 2 ;;
        --bundle-id) need_value "$@"; BUNDLE_ID="$2"; shift 2 ;;
        --dark)      APPEARANCE="dark"; shift ;;
        --ui-tests)  RUN_UI_TESTS=1; shift ;;
        --no-brew)   USE_BREW=0; shift ;;
        --no-open)   OPEN_UI=0; shift ;;
        --ci)        CI=1; OPEN_UI=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "mac_setup.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

SERVICE="https://www.fiveprime.org/api/t2"
TOTAL_STEPS=7
STEP=0
CURRENT="starting"
LOG=""
LOGS=""

# ------------------------------------------------------------------ output helpers
if [ -t 1 ]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""; fi
step() { STEP=$((STEP + 1)); CURRENT="$1"; printf '\n%s==> [%d/%d] %s%s\n' "$BOLD" "$STEP" "$TOTAL_STEPS" "$1" "$OFF"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s  %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '    %swarning%s  %s\n' "$YELLOW" "$OFF" "$*"; }
die() {
    trap - ERR
    printf '\n%sFAILED%s in step %d/%d (%s):\n' "$RED" "$OFF" "$STEP" "$TOTAL_STEPS" "$CURRENT" >&2
    while [ $# -gt 0 ]; do printf '    %s\n' "$1" >&2; shift; done
    if [ -n "$LOG" ]; then printf '    Full output of this run: %s\n' "$LOG" >&2; fi
    exit 1
}
trap 'die "an unexpected error on line $LINENO of mac_setup.sh (the lines above say more)"' ERR
trap 'sleep 1' EXIT        # lets the log writer (tee, below) finish before the shell goes away

# run a long command with its output in a log file; on failure show the useful part
#   run_logged <log name> <what it is> <command...>
run_logged() {
    local name="$1" what="$2"; shift 2
    local file="$LOGS/$name.log"
    info "$what  (output: $file)"
    if "$@" > "$file" 2>&1; then return 0; fi
    printf '\n' >&2
    # compiler / test errors first, then the end of the log
    grep -E "error:|Error:|\*\* .* FAILED|: error |XCTAssert|failed -|Testing failed" "$file" | sort -u | head -60 >&2 || true
    printf '    ...\n' >&2
    tail -25 "$file" >&2 || true
    die "$what failed." "Log: $file"
}

# ------------------------------------------------------------------ 1. the Mac
step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || { echo "mac_setup.sh is for macOS; this machine runs $(uname -s). Run it on the Mac." >&2; exit 1; }

case "$DEST" in
    "$SRC"|"$SRC"/*) die "--dest ($DEST) is inside the source folder. Choose a folder elsewhere, e.g. ~/T2Mobile." ;;
esac
mkdir -p "$DEST" || die "cannot create $DEST"
DEST="$(cd "$DEST" && pwd)"
LOGS="$DEST/logs"; SHOTS="$DEST/screenshots"; TOOLS="$DEST/tools"
mkdir -p "$LOGS" "$SHOTS" "$TOOLS"
LOG="$DEST/mac_setup.log"
# from here on, everything this script prints is also in the log
exec > >(tee "$LOG") 2>&1
info "$(date '+%Y-%m-%d %H:%M:%S')  mac_setup.sh  source: $SRC  ->  local folder: $DEST"

fs="$(df -P "$DEST" | awk 'NR==2 {print $1}')"
case "$fs" in
    /dev/*) ok "local folder is on a local disk ($fs)" ;;
    *) die "$DEST is not on a local disk (it is on $fs)." \
           "Xcode is slow and unreliable on network folders. Use --dest with a folder on this Mac." ;;
esac

info "macOS $(sw_vers -productVersion) ($(uname -m))"

if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode is not installed." \
        "Install Xcode from the App Store (free, about 10 GB), open it once, accept the licence" \
        "and let it install the iOS platform. Then run this script again."
fi
case "$(xcode-select -p)" in
    *CommandLineTools*)
        if [ -d /Applications/Xcode.app/Contents/Developer ]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
            info "using /Applications/Xcode.app (the selected developer folder is only the Command Line Tools)"
        else
            die "Only Apple's Command Line Tools are installed; an iPhone app needs the full Xcode." \
                "Install Xcode from the App Store (free, about 10 GB), open it once, accept the licence" \
                "and let it install the iOS platform. Then run this script again."
        fi ;;
esac
if ! xcode_version="$(xcodebuild -version 2>&1)"; then
    die "Xcode is installed but not ready: $(echo "$xcode_version" | head -2 | tr '\n' ' ')" \
        "Open Xcode once and accept the licence (or run: sudo xcodebuild -license accept)," \
        "wait until it has finished installing its components, then run this script again."
fi
xcode_name="$(echo "$xcode_version" | head -1)"
xcode_major="$(echo "$xcode_name" | awk '{print $2}' | cut -d. -f1)"
case "$xcode_major" in
    ''|*[!0-9]*) warn "could not read the Xcode version from: $xcode_name" ;;
    *) [ "$xcode_major" -ge 15 ] || die "$xcode_name is too old: the app needs Xcode 15 or newer (iOS 17 SDK)." \
                                        "Update Xcode in the App Store, then run this script again." ;;
esac
ok "$xcode_name, $(echo "$xcode_version" | sed -n 2p), iOS SDK $(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || echo '?')"
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    die "Xcode has not finished its first-launch setup." \
        "Open Xcode once and wait for 'Installing components' to finish (or run: xcodebuild -runFirstLaunch)," \
        "then run this script again."
fi
if ! xcrun simctl list runtimes 2>/dev/null | grep -q '^iOS'; then
    warn "no iOS Simulator is installed in this Xcode; downloading it now (about 8 GB, once)"
    info "(the same as Xcode > Settings > Components > iOS > Get)"
    xcodebuild -downloadPlatform iOS || die "could not download the iOS Simulator." \
        "In Xcode: Settings > Components (or Platforms) > iOS > Get. Then run this script again."
    xcrun simctl list runtimes | grep -q '^iOS' || die "the iOS Simulator is still not available after the download." \
        "Open Xcode > Settings > Components and check that iOS is installed."
fi
ok "iOS Simulator: $(xcrun simctl list runtimes | grep '^iOS' | tail -1 | sed 's/ (.*//')"
for tool in rsync curl unzip; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is missing (it is part of macOS; check your PATH: $PATH)"
done
if curl -fsS -m 20 "$SERVICE/healthz" >/dev/null 2>&1; then ok "the T2 data service answers ($SERVICE)"
else warn "the T2 data service does not answer from this Mac ($SERVICE): the app will build, but show a connection error"; fi

# ------------------------------------------------------------------ 2. local copy
step "Copying the sources to $DEST/ios"
# what Xcode generates, and this Mac's own settings, stay as they are in the copy
rsync -a --delete \
    --exclude '.build' --exclude '*.xcodeproj' --exclude 'DerivedData' --exclude 'xcuserdata' \
    --exclude 'Local.xcconfig' --exclude '.DS_Store' --exclude '.swiftpm' \
    "$SRC/" "$DEST/ios/"
ok "$(find "$DEST/ios" -name '*.swift' | wc -l | tr -d ' ') Swift files copied (re-running copies only what changed)"

APPDIR="$DEST/ios/T2App"
LOCALCFG="$APPDIR/Config/Local.xcconfig"
# set KEY = VALUE in Local.xcconfig, replacing an earlier value
set_local() {
    touch "$LOCALCFG"
    grep -v "^$1[ =]" "$LOCALCFG" > "$LOCALCFG.tmp" || true
    printf '%s = %s\n' "$1" "$2" >> "$LOCALCFG.tmp"
    mv "$LOCALCFG.tmp" "$LOCALCFG"
}
# a team chosen in Xcode's Signing & Capabilities lives only in the generated project:
# carry it over, so generating the project again does not lose it
if [ -z "$TEAM" ] && [ -f "$APPDIR/T2.xcodeproj/project.pbxproj" ] && ! grep -q '^DEVELOPMENT_TEAM' "$LOCALCFG" 2>/dev/null; then
    TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9][A-Z0-9]*\);.*/\1/p' "$APPDIR/T2.xcodeproj/project.pbxproj" | head -1)"
    if [ -n "$TEAM" ]; then info "keeping the team you chose in Xcode: $TEAM"; fi
fi
if [ -n "$TEAM" ]; then set_local DEVELOPMENT_TEAM "$TEAM"; fi
if [ -n "$BUNDLE_ID" ]; then set_local T2_BUNDLE_ID "$BUNDLE_ID"; fi
APP_ID=""
if [ -f "$LOCALCFG" ]; then
    info "this Mac's own settings ($LOCALCFG):"; sed 's/^/        /' "$LOCALCFG"
    APP_ID="$(sed -n 's/^T2_BUNDLE_ID *= *//p' "$LOCALCFG" | tail -1)"
fi
if [ -z "$APP_ID" ]; then APP_ID="$(sed -n 's/^T2_BUNDLE_ID *= *//p' "$APPDIR/Config/T2.xcconfig" | tail -1)"; fi
if [ -z "$APP_ID" ]; then die "no T2_BUNDLE_ID in $APPDIR/Config/T2.xcconfig"; fi

# ------------------------------------------------------------------ 3. XcodeGen, project
step "Generating the Xcode project (XcodeGen)"
XCODEGEN=""
if [ "$USE_BREW" = 1 ] && command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN="$(command -v xcodegen)"
elif [ -x "$TOOLS/xcodegen/bin/xcodegen" ] && "$TOOLS/xcodegen/bin/xcodegen" --version >/dev/null 2>&1; then
    XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"
elif [ "$USE_BREW" = 1 ] && command -v brew >/dev/null 2>&1; then
    run_logged brew-xcodegen "installing XcodeGen with Homebrew" brew install xcodegen
    XCODEGEN="$(command -v xcodegen)" || die "Homebrew installed xcodegen, but it is not on the PATH"
else
    url="https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip"
    [ -n "${XCODEGEN_VERSION:-}" ] && url="https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
    info "downloading XcodeGen's release binary into $TOOLS"
    info "$url"
    curl -fsSL --retry 3 -m 300 -o "$TOOLS/xcodegen.zip" "$url" || die "could not download XcodeGen from" "$url" \
        "Check the internet connection; or install it yourself (brew install xcodegen) and run this script again."
    rm -rf "$TOOLS/xcodegen"
    unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS" || die "could not unpack $TOOLS/xcodegen.zip"
    rm -f "$TOOLS/xcodegen.zip"
    XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"
    [ -x "$XCODEGEN" ] || die "the XcodeGen download does not contain bin/xcodegen (looked in $TOOLS/xcodegen)"
    "$XCODEGEN" --version >/dev/null 2>&1 || die "the downloaded XcodeGen does not run on this Mac ($(uname -m))." \
        "Install it another way (brew install xcodegen) and run this script again."
fi
ok "XcodeGen $("$XCODEGEN" --version 2>/dev/null | sed 's/^Version: //') at $XCODEGEN"
run_logged xcodegen "generating T2.xcodeproj" "$XCODEGEN" generate --spec "$APPDIR/project.yml" --project "$APPDIR"
[ -d "$APPDIR/T2.xcodeproj" ] || die "XcodeGen ran but $APPDIR/T2.xcodeproj does not exist"
ok "$APPDIR/T2.xcodeproj  (bundle id $APP_ID)"

# ------------------------------------------------------------------ 4. unit tests
step "Running the T2Kit unit tests (filtering, statistics, plot geometry)"
run_logged t2kit-tests "swift test" swift test --package-path "$DEST/ios/T2Kit"
summary="$(grep -E 'Executed [0-9]+ tests?, with' "$LOGS/t2kit-tests.log" | tail -1 | sed 's/^[[:space:]]*//' || true)"
ok "${summary:-all tests passed}"

# ------------------------------------------------------------------ 5. build
step "Building the app for the iOS Simulator"
# every available iPhone simulator as "runtime|name|udid|state", oldest iOS first
list_iphones() {
    xcrun simctl list devices available | awk '
        /^-- / { rt = $0; gsub(/^-- | --$/, "", rt); next }
        rt ~ /^iOS/ && match($0, /\([0-9A-F]+-[0-9A-F]+-[0-9A-F]+-[0-9A-F]+-[0-9A-F]+\)/) {
            udid = substr($0, RSTART + 1, RLENGTH - 2)
            name = substr($0, 1, RSTART - 2); sub(/^ +/, "", name)
            state = substr($0, RSTART + RLENGTH); gsub(/[() ]/, "", state)
            if (name ~ /^iPhone/) print rt "|" name "|" udid "|" state
        }'
}
pick_simulator() {
    local all line name
    all="$(list_iphones)"
    if [ -n "$DEVICE" ]; then
        line="$(echo "$all" | awk -F'|' -v want="$DEVICE" '$2 == want' | tail -1)"
        if [ -z "$line" ]; then
            # not there yet: create it (works when this Xcode knows the device type)
            info "creating a \"$DEVICE\" simulator" >&2
            xcrun simctl create "$DEVICE" "$DEVICE" >/dev/null 2>&1 || true
            line="$(list_iphones | awk -F'|' -v want="$DEVICE" '$2 == want' | tail -1)"
        fi
        echo "$line"; return 0
    fi
    line="$(echo "$all" | awk -F'|' '$4 == "Booted"' | tail -1)"
    if [ -n "$line" ]; then echo "$line"; return 0; fi
    for name in "iPhone 17 Pro" "iPhone 17" "iPhone 16 Pro" "iPhone 16" "iPhone 15 Pro" "iPhone 15"; do
        line="$(echo "$all" | awk -F'|' -v want="$name" '$2 == want' | tail -1)"
        if [ -n "$line" ]; then echo "$line"; return 0; fi
    done
    echo "$all" | tail -1
}
sim="$(pick_simulator)"
if [ -z "$sim" ]; then
    if [ -n "$DEVICE" ]; then
        die "there is no simulator named \"$DEVICE\" and it could not be created. Installed iPhones:" \
            "$(list_iphones | awk -F'|' '{print $2 " (" $1 ")"}' | sort -u | tr '\n' ';')"
    fi
    die "no iPhone simulator is installed." "In Xcode: Window > Devices and Simulators > Simulators > + ; then run this script again."
fi
SIM_RUNTIME="$(echo "$sim" | cut -d'|' -f1)"; SIM_NAME="$(echo "$sim" | cut -d'|' -f2)"; UDID="$(echo "$sim" | cut -d'|' -f3)"
ok "simulator: $SIM_NAME, $SIM_RUNTIME ($UDID)"

BUILD_ACTION="build"
if [ "$RUN_UI_TESTS" = 1 ]; then BUILD_ACTION="build-for-testing"; fi
run_logged build "xcodebuild $BUILD_ACTION (a first build takes a few minutes)" \
    xcodebuild -project "$APPDIR/T2.xcodeproj" -scheme T2 -configuration Debug \
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DEST/build" \
        "$BUILD_ACTION"
APP="$DEST/build/Build/Products/Debug-iphonesimulator/T2.app"
[ -d "$APP" ] || die "the build succeeded but $APP is missing"
warnings="$(grep -c ' warning: ' "$LOGS/build.log" || true)"
ok "built $APP  ($warnings compiler warning lines; see $LOGS/build.log)"

# ------------------------------------------------------------------ 6. simulator
step "Running the app in the simulator"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true        # "already booted" is fine
run_logged sim-boot "waiting for $SIM_NAME to finish booting" xcrun simctl bootstatus "$UDID" -b
if [ "$OPEN_UI" = 1 ]; then open -a Simulator || true; fi
xcrun simctl ui "$UDID" appearance "$APPEARANCE" >/dev/null 2>&1 || warn "could not set the $APPEARANCE appearance"
# a tidy status bar for the pictures (9:41, full battery); harmless if unsupported
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
run_logged sim-install "installing T2.app" xcrun simctl install "$UDID" "$APP"

WAIT=60; [ "$CI" = 1 ] && WAIT=180
# start the app on one of its tabs and photograph it once it says its data are on screen
# ("T2-READY" on its standard output), or after $WAIT seconds
#   shoot <file name> <launch arguments...>
shoot() {
    local file="$SHOTS/$1" out="$LOGS/app-$1.out" waited=0; shift
    : > "$out"
    xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
    xcrun simctl launch --stdout="$out" --stderr="$out" "$UDID" "$APP_ID" "$@" >/dev/null \
        || die "could not start the app in the simulator ($APP_ID)"
    while [ "$waited" -lt "$WAIT" ] && ! grep -q "T2-READY" "$out" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
    if grep -q "T2-READY" "$out" 2>/dev/null; then sleep 2      # let the last frame settle
    else warn "the app did not report its data within ${WAIT}s (no network? see $out)"; fi
    xcrun simctl io "$UDID" screenshot "$file.png" >/dev/null 2>&1 || die "could not take a screenshot of the simulator"
    ok "$file.png"
}
tag="$(echo "$SIM_NAME" | tr -c 'A-Za-z0-9\n' '-' | sed 's/--*/-/g; s/-$//')-$APPEARANCE"
shoot "$tag-1-select"  -t2Reset YES -t2Tab select
shoot "$tag-2-plot"    -t2Reset YES -t2Tab plot
shoot "$tag-3-filter"  -t2Reset YES -t2Tab filter
shoot "$tag-4-publish" -t2Reset YES -t2Tab publish

if [ "$RUN_UI_TESTS" = 1 ]; then
    info "UI tests: the app is driven through its main flows against the live service"
    UISHOTS="$SHOTS/ui-$tag"
    rm -rf "$UISHOTS" "$LOGS/ui-tests.xcresult"; mkdir -p "$UISHOTS"
    xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
    ui_failed=0
    TEST_RUNNER_T2_SCREENSHOT_DIR="$UISHOTS" xcodebuild -project "$APPDIR/T2.xcodeproj" -scheme T2 \
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DEST/build" \
        -resultBundlePath "$LOGS/ui-tests.xcresult" test-without-building > "$LOGS/ui-tests.log" 2>&1 || ui_failed=1
    # the screenshots are also attachments of the result bundle (Xcode shows them there)
    if [ -z "$(ls -A "$UISHOTS" 2>/dev/null)" ]; then
        xcrun xcresulttool export attachments --path "$LOGS/ui-tests.xcresult" --output-path "$UISHOTS" >/dev/null 2>&1 || true
    fi
    grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests?" "$LOGS/ui-tests.log" | sed 's/^/        /' || true
    info "$(ls "$UISHOTS" 2>/dev/null | wc -l | tr -d ' ') screenshots in $UISHOTS"
    if [ "$ui_failed" = 1 ]; then
        grep -E "error:|XCTAssert|failed -|Failing tests|\*\* TEST" "$LOGS/ui-tests.log" | sort -u | head -60 >&2 || true
        die "the UI tests failed." "Log: $LOGS/ui-tests.log   Result bundle (open in Xcode): $LOGS/ui-tests.xcresult"
    fi
    ok "UI tests passed"
fi

# ------------------------------------------------------------------ 7. Xcode, next steps
step "Done"
if [ "$OPEN_UI" = 1 ]; then
    open "$APPDIR/T2.xcodeproj"
    open "$SHOTS" || true
    info "Xcode is opening $APPDIR/T2.xcodeproj; the app is running in the Simulator window."
fi
trap - ERR
cat <<EOF

${BOLD}The app is built and ran in the simulator ($SIM_NAME).${OFF}
  Project      $APPDIR/T2.xcodeproj
  Screenshots  $SHOTS
  Log          $LOG

Work on the copy in $DEST/ios, or change the files where they came from and run this
script again (it copies only what changed and keeps your signing settings).
In Xcode: choose a simulator in the toolbar and press Run (Cmd-R).

${BOLD}A. On your own iPhone, with a free Apple ID (no membership needed)${OFF}
  1. Xcode > Settings > Accounts (in Xcode 26: Apple Accounts) > "+" > sign in with your Apple ID.
  2. In the left sidebar click the blue "T2" project, then target "T2" > "Signing & Capabilities":
     tick "Automatically manage signing" and choose Team: "<your name> (Personal Team)".
     If Xcode says the bundle identifier is not available, pick another one, for example
         $0 --bundle-id org.fiveprime.t2.$(id -un)
  3. Connect the iPhone with a cable, unlock it, tap "Trust This Computer".
     On the iPhone: Settings > Privacy & Security > Developer Mode > on (it restarts once).
  4. Choose your iPhone in Xcode's toolbar (where the simulator name is) and press Run.
  5. The first time, the phone refuses to open the app: on the iPhone go to
     Settings > General > VPN & Device Management > Developer App > your Apple ID > Trust.
     Press Run again.
  Limits of free signing: the app stops opening after 7 days (press Run again to renew it),
  three apps per phone, no TestFlight. The team you chose is remembered when this script
  runs again.

${BOLD}B. When the Apple Developer Program membership is active${OFF}
  1. Find your Team ID (10 characters) at https://developer.apple.com/account > Membership details,
     and run:    $0 --team YOURTEAMID
     (or choose the new team in Signing & Capabilities, as above). Apps then last a year on a phone.
  2. Bundle identifier: the App Store identity of the app, fixed after the first upload.
     It is "$APP_ID" now; change it with --bundle-id before uploading if you want another.
  3. https://appstoreconnect.apple.com > Apps > "+" > New App: platform iOS, name, the bundle id.
  4. In Xcode choose the destination "Any iOS Device (arm64)", then Product > Archive.
     In the Organizer window: Distribute App > App Store Connect (TestFlight) > Upload.
     Raise CURRENT_PROJECT_VERSION in T2App/Config/T2.xcconfig for every upload.
  5. TestFlight: internal testers can install minutes after processing; external testers
     need a short Beta App Review. For the App Store itself: screenshots, a privacy policy
     address, and the privacy answers ("Data Not Collected": the app only reads public data).

More: T2Mobile/docs/IOS.md and T2Mobile/NOTES.md.
EOF
