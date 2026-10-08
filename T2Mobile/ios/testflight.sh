#!/bin/bash
# testflight.sh -- archive the T2 iPhone app and upload it to App Store Connect (TestFlight),
# from the Mac, without opening Xcode.
#
#     ~/wherever/T2Mobile/ios/testflight.sh                 # archive + upload
#     ~/wherever/T2Mobile/ios/testflight.sh --archive-only  # just the .xcarchive (Organizer can upload it)
#     ~/wherever/T2Mobile/ios/testflight.sh --help
#
# Needs: an Apple Developer Program membership, the team set once with
# `mac_setup.sh --team ID` (kept in T2App/Config/Local.xcconfig), and the app record in App
# Store Connect (Apps > "+" > New App, bundle id as in Config/T2.xcconfig). Signing is
# automatic: Xcode makes the certificates and profiles itself (-allowProvisioningUpdates).
#
# Who is uploading: either the Apple ID signed in to Xcode on this Mac (Settings >
# Accounts), or an App Store Connect API key, which also works unattended. For the key:
# App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys >
# "+", access App Manager; download the .p8 (once) to ~/.appstoreconnect/private_keys/ and
# pass --key-id ID --issuer-id ID, or keep them with the team in
# ~/.appstoreconnect/t2-testflight.env (mode 600; T2_TEAM, T2_ASC_KEY_ID, T2_ASC_ISSUER_ID).
# The key and that file stay on this Mac; nothing of them goes into the repository.
#
# Over ssh the login keychain must be unlocked first (Xcode keeps the signing certificate
# there):  security unlock-keychain ~/Library/Keychains/login.keychain-db
#
# Build numbers: App Store Connect assigns the next one itself (manageAppVersionAndBuildNumber),
# so nothing has to be edited between uploads. MARKETING_VERSION (what testers see) is in
# Config/T2.xcconfig.
#
# Written for the bash 3.2 that macOS ships.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: testflight.sh [options]

  --archive-only     build the .xcarchive and stop (upload it from Xcode's Organizer later)
  --upload-only      upload the .xcarchive of the last run (build/T2.xcarchive) without rebuilding
  --key-id ID        App Store Connect API key id (with --issuer-id); default: $T2_ASC_KEY_ID
  --issuer-id ID     the key's issuer id; default: $T2_ASC_ISSUER_ID
  --key-path FILE    the .p8 file; default: the AuthKey_<ID>.p8 that xcodebuild finds itself
                     in ./private_keys, ~/private_keys, ~/.private_keys or
                     ~/.appstoreconnect/private_keys
  --team ID          the developer team (default: DEVELOPMENT_TEAM from Config/Local.xcconfig)
  -h, --help         this text

Defaults for all of these come from ~/.appstoreconnect/t2-testflight.env (mode 600; or the
file $T2_TESTFLIGHT_ENV): T2_TEAM, T2_ASC_KEY_ID, T2_ASC_ISSUER_ID.

Writes next to ios/ in the T2Mobile folder:  build/T2.xcarchive, build/export/ (the upload
receipt), logs/testflight-*.log
EOF
}

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$(dirname "$SRC")"
APPDIR="$SRC/T2App"
LOCALCFG="$APPDIR/Config/Local.xcconfig"
LOGS="$DEST/logs"; BUILD="$DEST/build"
mkdir -p "$LOGS" "$BUILD"

# this Mac's identifiers (team, key id, issuer id), kept outside the repository, mode 0600:
#   T2_TEAM=..., T2_ASC_KEY_ID=..., T2_ASC_ISSUER_ID=...
ENVFILE="${T2_TESTFLIGHT_ENV:-$HOME/.appstoreconnect/t2-testflight.env}"
if [ -f "$ENVFILE" ]; then
    case "$(stat -f '%Lp' "$ENVFILE")" in 600|400) ;; *) echo "testflight.sh: $ENVFILE must be mode 600 (chmod 600 $ENVFILE)" >&2; exit 2 ;; esac
    # shellcheck disable=SC1090
    . "$ENVFILE"
fi
ARCHIVE_ONLY=0; UPLOAD_ONLY=0; KEY_ID="${T2_ASC_KEY_ID:-}"; ISSUER_ID="${T2_ASC_ISSUER_ID:-}"; KEY_PATH=""; TEAM="${T2_TEAM:-}"
need_value() { [ $# -ge 2 ] || { echo "testflight.sh: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --archive-only) ARCHIVE_ONLY=1; shift ;;
        --upload-only)  UPLOAD_ONLY=1; shift ;;
        --key-id)       need_value "$@"; KEY_ID="$2"; shift 2 ;;
        --issuer-id)    need_value "$@"; ISSUER_ID="$2"; shift 2 ;;
        --key-path)     need_value "$@"; KEY_PATH="$2"; shift 2 ;;
        --team)         need_value "$@"; TEAM="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "testflight.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'; else BOLD=""; RED=""; GREEN=""; OFF=""; fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '    %sok%s  %s\n' "$GREEN" "$OFF" "$*"; }
die()  { printf '\n%sFAILED%s: ' "$RED" "$OFF" >&2; while [ $# -gt 0 ]; do printf '%s\n    ' "$1" >&2; shift; done; printf '\n' >&2; exit 1; }
run_logged() {
    local name="$1" what="$2"; shift 2
    local file="$LOGS/$name.log"
    printf '    %s  (output: %s)\n' "$what" "$file"
    if "$@" > "$file" 2>&1; then return 0; fi
    grep -E "error:|Error:|\*\* .* FAILED|: error " "$file" | sort -u | head -40 >&2 || true
    printf '    ...\n' >&2; tail -20 "$file" >&2 || true
    die "$what failed." "Log: $file"
}

# ------------------------------------------------------------------ what is needed
step "Checking"
[ "$(uname -s)" = "Darwin" ] || die "testflight.sh runs on the Mac"
if [ -z "$TEAM" ] && [ -f "$LOCALCFG" ]; then TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$LOCALCFG" | tail -1)"; fi
[ -n "$TEAM" ] || die "no developer team." "Run once:  $SRC/mac_setup.sh --team YOURTEAMID   (developer.apple.com/account > Membership details)"
APP_ID="$(sed -n 's/^T2_BUNDLE_ID *= *//p' "$LOCALCFG" 2>/dev/null | tail -1)"
[ -n "$APP_ID" ] || APP_ID="$(sed -n 's/^T2_BUNDLE_ID *= *//p' "$APPDIR/Config/T2.xcconfig" | tail -1)"
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$APPDIR/Config/T2.xcconfig" | tail -1)"
ok "team $TEAM, bundle id $APP_ID, version $VERSION"
if [ -n "$KEY_ID" ] || [ -n "$ISSUER_ID" ]; then
    [ -n "$KEY_ID" ] && [ -n "$ISSUER_ID" ] || die "--key-id and --issuer-id go together"
    if [ -z "$KEY_PATH" ]; then
        for d in ./private_keys "$HOME/private_keys" "$HOME/.private_keys" "$HOME/.appstoreconnect/private_keys"; do
            [ -f "$d/AuthKey_$KEY_ID.p8" ] && KEY_PATH="$d/AuthKey_$KEY_ID.p8" && break
        done
    fi
    [ -n "$KEY_PATH" ] && [ -f "$KEY_PATH" ] || die "the key file AuthKey_$KEY_ID.p8 was not found." \
        "Put it in ~/.appstoreconnect/private_keys/ (chmod 600) or give --key-path."
    ok "App Store Connect API key $KEY_ID ($KEY_PATH)"
    AUTH=(-authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID")
else
    AUTH=()
    ok "no API key: signing and upload use the Apple ID signed in to Xcode (Settings > Accounts)"
fi
if [ ! -d "$APPDIR/T2.xcodeproj" ]; then
    XCODEGEN="$(command -v xcodegen || true)"; [ -n "$XCODEGEN" ] || XCODEGEN="$DEST/tools/xcodegen/bin/xcodegen"
    [ -x "$XCODEGEN" ] || die "no T2.xcodeproj and no XcodeGen: run mac_setup.sh once first"
    run_logged testflight-xcodegen "generating T2.xcodeproj" "$XCODEGEN" generate --spec "$APPDIR/project.yml" --project "$APPDIR"
fi

# ------------------------------------------------------------------ archive
ARCHIVE="$BUILD/T2.xcarchive"
if [ "$UPLOAD_ONLY" = 1 ]; then
    step "Using the archive of the last run"
    [ -d "$ARCHIVE" ] || die "no $ARCHIVE: run without --upload-only first"
else
step "Archiving (Release, any iPhone)"
rm -rf "$ARCHIVE"
run_logged testflight-archive "xcodebuild archive" \
    xcodebuild -project "$APPDIR/T2.xcodeproj" -scheme T2 -configuration Release \
        -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -derivedDataPath "$BUILD" \
        -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
        DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic archive
fi
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist" 2>/dev/null || echo "$VERSION")"
ok "$ARCHIVE  (version $BUILT)"
if [ "$ARCHIVE_ONLY" = 1 ]; then
    cat <<EOF

To upload it: open Xcode > Window > Organizer > Archives, choose this archive,
Distribute App > App Store Connect > Upload.  Or run $0 without --archive-only.
EOF
    exit 0
fi

# ------------------------------------------------------------------ upload
step "Uploading to App Store Connect"
EXPORT="$BUILD/export"
rm -rf "$EXPORT"; mkdir -p "$EXPORT"
OPTIONS="$BUILD/ExportOptions.plist"
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><true/>
</dict>
</plist>
EOF
run_logged testflight-upload "xcodebuild -exportArchive (upload)" \
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$EXPORT" \
        -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}
printf '%s  version %s  team %s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$BUILT" "$TEAM" "$APP_ID" >> "$LOGS/testflight-uploads.txt"
ok "uploaded (receipt in $EXPORT; history in $LOGS/testflight-uploads.txt)"
cat <<EOF

${BOLD}Uploaded.${OFF} App Store Connect processes the build in 5-15 minutes (an email arrives).
Then: https://appstoreconnect.apple.com > Apps > T2 > TestFlight: the build appears under iOS;
add it to an Internal Testing group (you need the TestFlight app on the phone). The first
build only may ask the export-compliance question: the app uses only https (the answer is
already in Info.plist: ITSAppUsesNonExemptEncryption = false).
EOF
