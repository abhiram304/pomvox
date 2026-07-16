#!/usr/bin/env bash
#
# verify-update.sh — local end-to-end rehearsal of the in-app updater.
# Builds an "old" and a "new" Developer ID-signed Pomvox, serves a throwaway
# appcast on localhost, launches the old build against it, and tells you what
# to click and what to expect. Requires: GUI session, Developer ID cert,
# full Xcode. Run on the maintainer's Mac, never CI.
#
#   scripts/verify-update.sh
#
# What you should observe (the pass criteria from the design spec):
#   1. Old build launches; within ~seconds the Home banner shows
#      "Update available — v<new>".  NEVER any popup.
#   2. Click Update → inline download/progress → app relaunches by itself.
#   3. After relaunch, this script confirms the installed bundle's
#      CFBundleShortVersionString is the new version.
#   4. TCC: mic / input-monitoring rows survive (same team + bundle id).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="/tmp/pomvox-update-rehearsal"; DD="$WORK/dd"
APPDIR="$HOME/Applications"; PORT=8000

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK/feed"

CUR_SHORT="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' Pomvox/project.yml)"
CUR_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' Pomvox/project.yml)"
NEW_SHORT="${CUR_SHORT%.*}.$(( ${CUR_SHORT##*.} + 1 ))-rehearsal"
NEW_BUILD=$(( CUR_BUILD + 1000 ))   # clearly synthetic, always newer

say "Throwaway EdDSA key (isolated Keychain account; never the real signing key)"
BIN="$(scripts/sparkle-tools.sh)"
KEY="$WORK/test.key"
KEYCHAIN_ACCOUNT="pomvox-e2e-test"
SERVER=""
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  security delete-generic-password -a "$KEYCHAIN_ACCOUNT" -s "https://sparkle-project.org" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT
# generate_keys has no keychain-free mode: it always stores the private key
# as a login-keychain item. Using a dedicated --account keeps this rehearsal
# key a completely separate keychain item from the real production signing
# key (the default account, with no --account flag). -x exports the private
# half to a file for sign_update; -p prints the base64 public half.
"$BIN/generate_keys" --account "$KEYCHAIN_ACCOUNT" >/dev/null
"$BIN/generate_keys" --account "$KEYCHAIN_ACCOUNT" -x "$KEY" >/dev/null
PUB="$("$BIN/generate_keys" --account "$KEYCHAIN_ACCOUNT" -p)"
[ -n "$PUB" ] || die "could not read the throwaway public key"

build_signed() { # $1=short $2=build $3=pubkey $4=outdir
  ( cd Pomvox && xcodegen generate >/dev/null )
  xcodebuild -project Pomvox/Pomvox.xcodeproj -scheme Pomvox -configuration Release \
    -derivedDataPath "$DD" -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$1" CURRENT_PROJECT_VERSION="$2" clean build | tail -2
  # Override the public key + feed inside the built app for the rehearsal:
  PL="$DD/Build/Products/Release/Pomvox.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $3" "$PL"
  codesign --force --deep --timestamp --options runtime \
    --entitlements Pomvox/Pomvox.entitlements \
    --sign "Developer ID Application" "$DD/Build/Products/Release/Pomvox.app"
  rm -rf "$4"; mkdir -p "$4"
  cp -R "$DD/Build/Products/Release/Pomvox.app" "$4/"
}

say "Building OLD ($CUR_SHORT/$CUR_BUILD) and NEW ($NEW_SHORT/$NEW_BUILD)"
build_signed "$CUR_SHORT" "$CUR_BUILD" "$PUB" "$WORK/old"
build_signed "$NEW_SHORT" "$NEW_BUILD" "$PUB" "$WORK/new"

say "Zipping + signing the NEW build, generating the local appcast"
/usr/bin/ditto -c -k --keepParent "$WORK/new/Pomvox.app" "$WORK/feed/Pomvox.zip"
SIG="$("$BIN/sign_update" --ed-key-file "$KEY" "$WORK/feed/Pomvox.zip" \
      | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LEN="$(stat -f %z "$WORK/feed/Pomvox.zip")"
cat > "$WORK/feed/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.sparkle-project.org/xml/rss/1.0/modules/sparkle">
  <channel><title>Pomvox rehearsal</title>
    <item>
      <title>Version $NEW_SHORT</title>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$NEW_SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="http://localhost:$PORT/Pomvox.zip" length="$LEN"
                 type="application/octet-stream" sparkle:edSignature="$SIG"/>
    </item>
  </channel>
</rss>
EOF

say "Installing OLD into $APPDIR and serving the feed"
rm -rf "$APPDIR/Pomvox.app"; cp -R "$WORK/old/Pomvox.app" "$APPDIR/"
( cd "$WORK/feed" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
SERVER=$!
sleep 1

say "Launching — click Update on the Home banner when it appears"
open -W --env POMVOX_UPDATE_FEED="http://localhost:$PORT/appcast.xml" \
  "$APPDIR/Pomvox.app" || true
# (If the banner never appears, `open --env` may not have propagated — launch
#  the binary directly instead:
#  POMVOX_UPDATE_FEED="http://localhost:$PORT/appcast.xml" \
#    "$APPDIR/Pomvox.app/Contents/MacOS/Pomvox")

say "After the relaunch settles, verifying the installed version"
sleep 5
INSTALLED="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APPDIR/Pomvox.app/Contents/Info.plist")"
if [ "$INSTALLED" = "$NEW_SHORT" ]; then
  printf '\n\033[1;32m✓ PASS — installed version is %s\033[0m\n' "$INSTALLED"
else
  die "installed version is $INSTALLED, expected $NEW_SHORT (did you click Update?)"
fi
echo "Cleanup: rm -rf $WORK; delete $APPDIR/Pomvox.app when done."
echo "  (the throwaway '$KEYCHAIN_ACCOUNT' Keychain item is removed automatically on exit)"
