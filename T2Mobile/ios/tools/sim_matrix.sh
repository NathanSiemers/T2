#!/bin/bash
# Run the UI tests (T2UITests) on several iPhone simulators, light and dark, building once.
# Runs on the Mac, in the T2Mobile folder (the one around ios/):
#   ./ios/tools/sim_matrix.sh "iPhone SE (3rd generation)":light "iPhone 13 mini":dark ...
# with no arguments: the list at the end of this file. A simulator that does not exist is
# created from the newest installed iOS runtime (it shares the runtime; a few hundred MB).
# Results: logs/matrix/summary.txt, logs/matrix/ui-<device>-<appearance>.{log,xcresult},
# screenshots/ui-<device>-<appearance>/. A freshly created simulator is booted once before
# it is used: xcodebuild does not see it for the first seconds of its life.
set -u
cd "$(dirname "$0")/../.." || exit 1
APPDIR=ios/T2App; APP_ID=org.fiveprime.t2; LOGS=logs/matrix; SHOTS=screenshots
mkdir -p "$LOGS"
SUMMARY="$LOGS/summary.txt"; : > "$SUMMARY"
echo "matrix started $(date)" | tee -a "$SUMMARY"

RUNTIME=$(xcrun simctl list runtimes | grep '^iOS' | tail -1 | sed 's/.* - //')
udid_for() {
    local name="$1" u
    u=$(xcrun simctl list devices available | grep -F "    $name (" | head -1 | sed 's/.*(\([0-9A-F-]*\)) (.*/\1/')
    if [ -z "$u" ]; then
        u=$(xcrun simctl create "$name" "$name" "$RUNTIME" 2>>"$LOGS/create.log") || u=""
        echo "created $name -> ${u:-FAILED}" | tee -a "$SUMMARY"
        if [ -n "$u" ]; then xcrun simctl boot "$u" >/dev/null 2>&1; xcrun simctl bootstatus "$u" -b >/dev/null 2>&1; sleep 15; fi
    fi
    echo "$u"
}

echo "== building for testing $(date)" | tee -a "$SUMMARY"
DEV=$(udid_for "iPhone 18 Pro")
xcodebuild -project $APPDIR/T2.xcodeproj -scheme T2 -destination "platform=iOS Simulator,id=$DEV" \
    -derivedDataPath build build-for-testing > "$LOGS/build.log" 2>&1 || { echo "BUILD FAILED (see $LOGS/build.log)" | tee -a "$SUMMARY"; exit 1; }
echo "build ok $(date)" | tee -a "$SUMMARY"

run_one() {   # run_one "device name" light|dark
    local name="$1" app="$2" udid tag log failed=0
    udid=$(udid_for "$name")
    if [ -z "$udid" ]; then echo "SKIP $name ($app): no simulator" | tee -a "$SUMMARY"; return; fi
    tag="$(echo "$name" | tr -c 'A-Za-z0-9\n' '-' | sed 's/--*/-/g; s/-$//')-$app"
    log="$LOGS/ui-$tag.log"
    echo "== $name $app $(date)" | tee -a "$SUMMARY"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
    xcrun simctl ui "$udid" appearance "$app" >/dev/null 2>&1 || echo "  could not set $app" | tee -a "$SUMMARY"
    xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 \
        --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
    xcrun simctl terminate "$udid" "$APP_ID" >/dev/null 2>&1 || true
    rm -rf "$SHOTS/ui-$tag" "$LOGS/ui-$tag.xcresult"; mkdir -p "$SHOTS/ui-$tag"
    TEST_RUNNER_T2_SCREENSHOT_DIR="$PWD/$SHOTS/ui-$tag" xcodebuild -project $APPDIR/T2.xcodeproj -scheme T2 \
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build \
        -retry-tests-on-failure -test-iterations 2 -only-testing:T2UITests \
        -resultBundlePath "$LOGS/ui-$tag.xcresult" test-without-building > "$log" 2>&1 || failed=1
    grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests?" "$log" | sed 's/^/    /' | tee -a "$SUMMARY"
    if [ $failed = 1 ]; then
        echo "  FAILED: $name $app" | tee -a "$SUMMARY"
        grep -E "error:|XCTAssert|failed -" "$log" | sort -u | head -20 | sed 's/^/    /' | tee -a "$SUMMARY"
    else echo "  passed: $name $app ($(ls "$SHOTS/ui-$tag" | wc -l | tr -d ' ') screenshots)" | tee -a "$SUMMARY"; fi
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
}

if [ $# -gt 0 ]; then
    for spec in "$@"; do run_one "${spec%:*}" "${spec##*:}"; done
else
    run_one "iPhone SE (3rd generation)" light
    run_one "iPhone SE (3rd generation)" dark
    run_one "iPhone 13 mini" dark
    run_one "iPhone 17e" light
    run_one "iPhone Air" dark
    run_one "iPhone 17" dark
    run_one "iPhone 18 Pro" dark
    run_one "iPhone 18 Pro Max" dark
fi
echo "matrix finished $(date)" | tee -a "$SUMMARY"
