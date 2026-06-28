#!/usr/bin/env bash
#
# notarize-release.sh — build, sign, notarize, and staple a distributable Murmur.app.
#
# This is the M7b distribution pipeline. It builds the Release configuration
# (Developer ID Application + hardened runtime + Murmur.entitlements, see
# Murmur/project.yml), submits the app to Apple's notary service, and staples the
# ticket so Gatekeeper accepts it offline. The result is a zip you can hand out.
#
# ── One-time setup ──────────────────────────────────────────────────────────
#   1. Create the signing cert (once): Xcode ▸ Settings ▸ Accounts ▸ your Apple
#      ID ▸ Manage Certificates ▸ "+" ▸ "Developer ID Application".
#
#   2. Create an app-specific password at appleid.apple.com ▸ Sign-In & Security
#      ▸ App-Specific Passwords, then store a notarytool keychain profile (once):
#
#        xcrun notarytool store-credentials "murmur-notary" \
#          --apple-id "you@example.com" --team-id "CT84AT52RS" \
#          --password "abcd-efgh-ijkl-mnop"
#
#      (An App Store Connect API key works too — pass --key/--key-id/--issuer
#      to `notarytool submit` instead of --keychain-profile.)
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   scripts/notarize-release.sh
#
# Override any of these via the environment:
#   TEAM_ID        Apple Developer team id            (default: CT84AT52RS)
#   NOTARY_PROFILE notarytool keychain profile name   (default: murmur-notary)
#   DEVELOPER_DIR  Xcode.app developer dir            (default: /Applications/Xcode.app/...)
#   DD             derived-data path (keep OFF iCloud) (default: /tmp/murmur-release-dd)
#   OUT            output dir for the zip             (default: ./dist)
#
set -euo pipefail

TEAM_ID="${TEAM_ID:-CT84AT52RS}"
NOTARY_PROFILE="${NOTARY_PROFILE:-murmur-notary}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DD="${DD:-/tmp/murmur-release-dd}"           # never build on the iCloud Desktop —
OUT="${OUT:-$(pwd)/dist}"                     # codesign rejects iCloud xattrs.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ_DIR="$REPO_ROOT/Murmur"
APP="$DD/Build/Products/Release/Murmur.app"
ZIP="$OUT/Murmur.zip"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────
say "Preflight"
[ -d "$DEVELOPER_DIR" ] || die "DEVELOPER_DIR not found: $DEVELOPER_DIR (install Xcode, not just CLT)."

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  die "No 'Developer ID Application' certificate in the keychain.
     Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application."
fi
echo "  ✓ Developer ID Application cert present"
echo "  ✓ team $TEAM_ID, notary profile '$NOTARY_PROFILE'"

command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)."

# ── Build (Release: Developer ID + hardened runtime + entitlements) ──────────
say "Generating project"
( cd "$PROJ_DIR" && xcodegen generate >/dev/null )

say "Building Release"
xcodebuild \
  -project "$PROJ_DIR/Murmur.xcodeproj" \
  -scheme Murmur \
  -configuration Release \
  -derivedDataPath "$DD" \
  -destination 'generic/platform=macOS' \
  clean build | tail -5

[ -d "$APP" ] || die "Build did not produce $APP"

# ── Verify the signature before we waste a notary round-trip ─────────────────
say "Verifying signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
  || die "App is not Developer-ID-signed with the hardened runtime — check project.yml Release config."
echo "  ✓ signed + hardened"

# ── Notarize ─────────────────────────────────────────────────────────────────
mkdir -p "$OUT"
say "Zipping for notarization"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

say "Submitting to Apple notary (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
  || die "Notarization failed. Inspect the log:
     xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"

# ── Staple + repackage the stapled app ───────────────────────────────────────
say "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

say "Repackaging stapled app"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# Final Gatekeeper assessment — what a downloader's Mac will actually decide.
say "Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP" || true

say "Done → $ZIP"
echo "  Distribute this zip. To make a .dmg instead, staple the .dmg too:"
echo "    xcrun stapler staple Murmur.dmg"
