#!/usr/bin/env bash
#
# make-appcast.sh — sign a release zip and update appcast.xml for Sparkle.
#
# Runs AFTER scripts/notarize-release.sh has produced dist/Pomvox.zip and AFTER
# the matching GitHub release + assets are published. See the in-app-updates
# design doc (§Release pipeline). Order matters: publish the GitHub release with
# assets FIRST, then run this and commit appcast.xml — no client may ever see an
# appcast entry whose enclosure 404s.
#
# ── One-time setup ──────────────────────────────────────────────────────────
#   Run Sparkle's generate_keys once (from the Sparkle SPM artifacts' bin dir):
#     ./bin/generate_keys
#   The private key goes into your login Keychain; the printed base64 public key
#   goes into project.yml (INFOPLIST_KEY_SUPublicEDKey) and must appear in the
#   built app's Contents/Info.plist. Export ONE offline backup of the private
#   key (losing it strands every user) and store a copy as a GH Actions secret.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   scripts/make-appcast.sh 0.1.11
#
# Env overrides:
#   SPARKLE_BIN   dir containing generate_appcast/sign_update (default: on PATH)
#   ZIP           the notarized zip                 (default: ./dist/Pomvox.zip)
#   OWNER_REPO    GitHub owner/repo                 (default: abhiram304/pomvox)
set -euo pipefail

VERSION="${1:?usage: make-appcast.sh <version>   e.g. 0.1.11}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="${ZIP:-$REPO_ROOT/dist/Pomvox.zip}"
OWNER_REPO="${OWNER_REPO:-abhiram304/pomvox}"
APPCAST="$REPO_ROOT/appcast.xml"
DL_PREFIX="https://github.com/$OWNER_REPO/releases/download/v$VERSION/"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Locate Sparkle's generate_appcast (from the SPM checkout's artifacts, or PATH).
GEN_APPCAST="$(command -v generate_appcast || true)"
if [ -z "$GEN_APPCAST" ] && [ -n "${SPARKLE_BIN:-}" ]; then
  GEN_APPCAST="$SPARKLE_BIN/generate_appcast"
fi
[ -x "$GEN_APPCAST" ] || die "generate_appcast not found. Set SPARKLE_BIN to Sparkle's bin dir
   (e.g. ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin)."

[ -f "$ZIP" ] || die "Release zip not found: $ZIP (run scripts/notarize-release.sh first)."

# generate_appcast reads a folder of archives + the Keychain private key and
# emits a fully-formed appcast (edSignature, length, etc.).
say "Signing $ZIP and generating the appcast item"
WORK="$(mktemp -d)"
cp "$ZIP" "$WORK/Pomvox-$VERSION.zip"
"$GEN_APPCAST" "$WORK" --download-url-prefix "$DL_PREFIX" -o "$WORK/appcast.xml"

# ── Validate before we commit (design §Release pipeline step 4) ──────────────
say "Validating"
python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('$WORK/appcast.xml')" \
  || die "generated appcast is not well-formed XML"

ENCLOSURE_URL="$(python3 - "$WORK/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
urls = [e.get("url") for e in t.iter("enclosure")]
print(urls[-1] if urls else "")
PY
)"
[ -n "$ENCLOSURE_URL" ] || die "no <enclosure> in the generated appcast"
say "Checking enclosure resolves: $ENCLOSURE_URL"
code="$(curl -sL -o /dev/null -w '%{http_code}' "$ENCLOSURE_URL" || echo 000)"
[ "$code" = "200" ] || die "enclosure URL returned HTTP $code — publish the GitHub release + assets first."

cp "$WORK/appcast.xml" "$APPCAST"
rm -rf "$WORK"

say "Done"
echo "  Updated $APPCAST for v$VERSION."
echo "  Review it, then: git add appcast.xml && git commit -m 'chore(appcast): v$VERSION' && git push"
