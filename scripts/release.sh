#!/usr/bin/env bash
# Cuts a release: builds the DMG, then regenerates the Sparkle appcast that points at it.
#
# The two are done together on purpose. An appcast that disagrees with the DMG beside it
# is the one failure mode of an auto-updater that reaches every user at once — either
# nobody is offered the update, or everybody is offered a download that 404s.
#
# Usage: scripts/release.sh
#
# Afterwards, create a GitHub release tagged v<version> and upload BOTH files from dist/:
#   Qingyu-<version>.dmg   the update itself
#   appcast.xml            what Sparkle reads; SUFeedURL points at /releases/latest/download/
# Sparkle checks the EdDSA signature in the appcast against SUPublicEDKey in Info.plist,
# so the private key in your login Keychain is what makes an update installable. Losing it
# means no existing install can ever be updated again; leaking it means anyone can ship
# those installs whatever they like.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
REPO="rhklite/qingyu"
DIST="$ROOT/dist"
APPCAST_DIR="$DIST/appcast-staging"

GENERATE="$ROOT/third_party/Sparkle/bin/generate_appcast"
[[ -x "$GENERATE" ]] || { echo "Missing $GENERATE — is third_party/Sparkle vendored?" >&2; exit 1; }

# Braced: a bare $VERSION immediately followed by a multibyte character is read as part
# of the variable name under a non-UTF-8 locale, and `set -u` then aborts the release.
echo "Building the DMG for ${VERSION}…"
"$ROOT/scripts/makedmg.sh"
DMG="$DIST/Qingyu-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "Expected $DMG — makedmg.sh did not produce it." >&2; exit 1; }

# generate_appcast reads a directory and writes one appcast describing everything in it.
# Give it only this release: older DMGs left in dist/ would otherwise reappear in the feed
# and, being older, do nothing but slow the check down.
rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"

echo "Signing and generating the appcast…"
"$GENERATE" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    "$APPCAST_DIR"

mv "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"
rm -rf "$APPCAST_DIR"

# A feed that doesn't name this version would ship a silent no-op update check.
grep -q "$VERSION" "$DIST/appcast.xml" ||
    { echo "appcast.xml does not mention $VERSION — refusing to publish it." >&2; exit 1; }
grep -q 'edSignature' "$DIST/appcast.xml" ||
    { echo "appcast.xml carries no EdDSA signature — Sparkle would reject the update." >&2; exit 1; }

cat <<EOF

Ready to publish $VERSION:
  $DMG
  $DIST/appcast.xml

  gh release create "v$VERSION" \\
      "$DMG" "$DIST/appcast.xml" \\
      --repo "$REPO" --title "轻语 $VERSION" --notes "…what changed…"

The release notes become what users read in the update window, so write them for Helena,
not for git. Existing installs pick this up within a day, or immediately via
"Check for Updates…".
EOF
