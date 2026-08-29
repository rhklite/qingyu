#!/usr/bin/env bash
# Builds 轻语.dmg for handing to someone else (AirDrop, upload…).
#
# The DMG needs no Xcode Command Line Tools and no CMake on the receiving Mac. The app
# is universal (arm64 + x86_64); the speech model is NOT bundled — on first launch the
# app asks which model to use and downloads it (ModelChooser + ModelDownloader), which
# keeps this file around 10 MB instead of 1.1 GB.
#
# Usage: scripts/makedmg.sh [output.dmg]
#   QINGYU_DMG_MODELS  optionally bundle models for a fully offline DMG, e.g.
#                      QINGYU_DMG_MODELS="ggml-medium-q5_0.bin" scripts/makedmg.sh
#                      (taken from ~/.config/qingyu/models; the app prefers a bundled
#                      copy over downloading — see AppDelegate.resolvedModelPath)
#
# Gatekeeper rejects the first launch of a build signed with anything other than an Apple
# Developer ID — "Apple could not verify 轻语 is free of malware" — and it does so whether
# or not the file was quarantined, because macOS scans on first exec either way. The
# recipient can get past it (System Settings > Privacy & Security > Open Anyway, which the
# window background spells out), but the only way to stop it being asked is to notarise:
#   QINGYU_SIGN_ID        "Developer ID Application: Name (TEAMID)" — signs with the
#                         hardened runtime, which notarisation requires.
#   QINGYU_NOTARY_PROFILE a profile from `xcrun notarytool store-credentials`; submits
#                         the finished DMG and staples the ticket into it.
# Unset, both are skipped and the DMG is signed locally as before.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
# Default output lives with the project, not in Downloads, so the artifact sits next
# to the source that produced it. Pass a path to override.
OUT="${1:-$ROOT/dist/Qingyu-$VERSION.dmg}"
mkdir -p "$(dirname "$OUT")"

# Both the volume icon and the app's own icon come from here. A DMG without it looks
# like a generic disk image, and nothing downstream complains — so a missing file is a
# build failure, checked before the long compile rather than after it.
ICON="$ROOT/Resources/AppIcon.icns"
[[ -f "$ICON" ]] || {
    echo "Missing $ICON — refusing to build a DMG with no icon." >&2; exit 1; }

MODELS_DIR="$HOME/.config/qingyu/models"
# Empty by default: models are downloaded by the app, not shipped.
MODELS="${QINGYU_DMG_MODELS:-}"
for m in $MODELS; do
    [[ -f "$MODELS_DIR/$m" ]] || {
        echo "Missing $MODELS_DIR/$m — run: scripts/download_model.sh ${m#ggml-}" >&2
        echo "(strip the ggml- prefix and .bin suffix, e.g. medium-q5_0)" >&2
        exit 1
    }
done

# Stage outside the repo: it sits in a synced folder, and the file provider re-tags
# .app bundles with com.apple.FinderInfo, which makes codesign fail.
STAGE="$(mktemp -d)"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" && -d "$MOUNT" ]] && { hdiutil detach "$MOUNT" -quiet 2>/dev/null ||
        hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; }
    rm -rf "$STAGE"
}
trap cleanup EXIT
DMGROOT="$STAGE/dmg"
mkdir -p "$DMGROOT"

# build.sh installs the .app wherever QINGYU_APP_DIR points, and signs it there.
echo "Building 轻语.app…"
QINGYU_APP_DIR="$DMGROOT" "$ROOT/scripts/build.sh"
APP="$DMGROOT/轻语.app"

if [[ -n "$MODELS" ]]; then
    mkdir -p "$APP/Contents/Resources/models"
    for m in $MODELS; do
        echo "Bundling $m ($(du -h "$MODELS_DIR/$m" | cut -f1))…"
        cp "$MODELS_DIR/$m" "$APP/Contents/Resources/models/"
    done
else
    echo "No models bundled — the app downloads one on first launch."
fi

# Adding a resource invalidates the signature build.sh applied — re-sign the bundle.
SIGN_KC="$HOME/Library/Keychains/qingyu-signing.keychain-db"
if [[ -n "${QINGYU_SIGN_ID:-}" ]]; then
    # --options runtime is what notarisation checks for; --timestamp is what keeps the
    # signature valid once the certificate itself expires.
    SIGN_ARGS=(--sign "$QINGYU_SIGN_ID" --options runtime --timestamp)
elif security find-identity "$SIGN_KC" 2>/dev/null | grep -q "Qingyu Local Dev"; then
    security unlock-keychain -p "qingyu-local-signing" "$SIGN_KC" 2>/dev/null || true
    SIGN_ARGS=(--sign "Qingyu Local Dev" --keychain "$SIGN_KC")
else
    SIGN_ARGS=(--sign -)
fi
echo "Signing the bundle…"
for _ in 1 2 3 4 5; do
    xattr -cr "$APP" 2>/dev/null || true
    codesign --force --deep "${SIGN_ARGS[@]}" \
        --entitlements "$ROOT/Resources/Qingyu.entitlements" "$APP" 2>/tmp/qingyu-dmg-codesign.err && break
    sleep 0.4
done
codesign --verify --strict --deep "$APP" || { cat /tmp/qingyu-dmg-codesign.err >&2; exit 1; }

ln -s /Applications "$DMGROOT/Applications"

# The drag-to-Applications window: a background picture with an arrow, plus icon
# positions on top of it. Both scales go into one TIFF so the window stays sharp on
# Retina; the dot-prefixed names keep them out of the window itself.
echo "Drawing the window background…"
mkdir -p "$DMGROOT/.background"
swift "$ROOT/scripts/dmg_background.swift" "$STAGE/bg.png" "$STAGE/bg@2x.png"
tiffutil -cathidpicheck "$STAGE/bg.png" "$STAGE/bg@2x.png" \
    -out "$DMGROOT/.background/background.tiff" >/dev/null

# Finder can only record a window layout onto a mounted, writable volume, so build a
# read/write image, let Finder dress it, then compress that into the DMG we ship.
echo "Laying out the window…"
# Finder stores the background picture as an alias holding the path it saw, so the
# volume has to land on /Volumes/轻语. A copy of an older DMG left mounted there would
# push this one to "/Volumes/轻语 1" and the shipped DMG would open with no background.
if [[ -d "/Volumes/轻语" ]]; then
    # A Finder window left open on the volume is enough to make a polite eject fail, and
    # that is the normal state right after someone looks at the DMG this script just made.
    echo "  ejecting the 轻语 volume already mounted at /Volumes/轻语…"
    hdiutil detach "/Volumes/轻语" -quiet 2>/dev/null ||
        hdiutil detach "/Volumes/轻语" -force -quiet ||
        { echo "Could not eject /Volumes/轻语 — eject it in Finder and re-run." >&2; exit 1; }
fi
RW="$STAGE/rw.dmg"
hdiutil create -volname "轻语" -srcfolder "$DMGROOT" -fs HFS+ -format UDRW \
    -size "$(( $(du -sm "$DMGROOT" | cut -f1) + 64 ))m" -ov "$RW" >/dev/null
MOUNT="$(hdiutil attach "$RW" -readwrite -nobrowse -noautoopen |
    awk -F'\t' '/\/Volumes\//{ print $NF }' | tail -1)"
[[ "$MOUNT" == "/Volumes/轻语" ]] ||
    { echo "Mounted at '$MOUNT', expected /Volumes/轻语 — refusing to bake a broken layout." >&2; exit 1; }

# Icon coordinates are centres in the picture's top-left space and must match the arrow
# drawn by dmg_background.swift. The window is 54pt taller than the 440pt of picture it
# shows, which is what the title bar and (if the recipient has it on) the path bar eat.
# Finder automation is denied by default, so a refusal here costs the layout, not the DMG.
osascript <<APPLESCRIPT || echo "  (Finder refused to lay out the window — the DMG is fine, just plain.
   Allow Terminal under System Settings > Privacy & Security > Automation > Finder.)" >&2
tell application "Finder"
    tell disk "轻语"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {180, 120, 820, 614}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "轻语.app" to {170, 190}
        set position of item "Applications" to {470, 190}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# Both of these go last, and in this order, because laying the window out makes Finder
# take the volume's icon into its own hands: it deletes .VolumeIcon.icns outright and
# clears the flag that points at it. Staging the icon before `hdiutil create` — which is
# where it used to live — therefore shipped a DMG carrying the flag with no icon behind
# it, i.e. a generic disk image. Copy it back after Finder is done, then re-set the flag.
echo "Applying the volume icon…"
cp "$ICON" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" || { echo "SetFile failed — the volume icon would not show." >&2; exit 1; }

sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
MOUNT=""

echo "Packing ${OUT}…"
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null

# Inspect what actually shipped. The icon is the one part of this build that fails
# silently — a dropped file or a cleared flag just yields a generic disk image, which
# nobody notices until the DMG is already in someone else's hands.
echo "Verifying the icons…"
MOUNT="$(hdiutil attach "$OUT" -readonly -nobrowse -noautoopen |
    awk -F'\t' '/\/Volumes\//{ print $NF }' | tail -1)"
icons_ok=true
[[ -f "$MOUNT/.VolumeIcon.icns" ]] ||
    { echo "  volume icon (.VolumeIcon.icns) missing" >&2; icons_ok=false; }
[[ "$(GetFileInfo -a "$MOUNT" 2>/dev/null)" == *C* ]] ||
    { echo "  custom-icon flag not set on the volume" >&2; icons_ok=false; }
[[ -f "$MOUNT/轻语.app/Contents/Resources/AppIcon.icns" ]] ||
    { echo "  app icon missing from the bundle" >&2; icons_ok=false; }
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
MOUNT=""
[[ "$icons_ok" == true ]] || { rm -f "$OUT"; echo "Icon check failed — DMG discarded." >&2; exit 1; }

if [[ -n "${QINGYU_NOTARY_PROFILE:-}" ]]; then
    # Notarising the DMG covers the app inside it, and stapling writes the ticket into the
    # file so the receiving Mac never has to reach Apple to check.
    echo "Notarising (a few minutes)…"
    xcrun notarytool submit "$OUT" --keychain-profile "$QINGYU_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    spctl -a -t open --context context:primary-signature -v "$OUT"
else
    echo "Not notarised — the first launch on another Mac will say Apple cannot verify it."
    echo "  Get past it: System Settings > Privacy & Security > Open Anyway."
fi

# The icon on the .dmg file itself is a separate mechanism from the volume icon above,
# and it is the one you actually see sitting in a folder: it lives in the file's resource
# fork rather than inside the image, so a DMG whose mounted volume is perfectly iconed
# still shows up in Finder as a generic white disk. Applied last because notarising and
# stapling rewrite the file.
echo "Applying the file icon…"
cp "$ICON" "$STAGE/fileicon.icns"
sips -i "$STAGE/fileicon.icns" >/dev/null            # icns → icon resource
DeRez -only icns "$STAGE/fileicon.icns" > "$STAGE/icon.rsrc"
Rez -append "$STAGE/icon.rsrc" -o "$OUT"
SetFile -a C "$OUT"

# Same reasoning as the volume-icon check: this fails invisibly, so confirm it stuck.
[[ "$(GetFileInfo -a "$OUT")" == *C* ]] ||
    { echo "Custom-icon flag not set on $OUT." >&2; exit 1; }
# Read the resource back rather than just checking the fork exists — a truncated or
# empty fork passes the latter and still shows a generic icon.
#
# Captured into a variable rather than piped into `grep -q`: grep exits at the first
# match, DeRez then dies of SIGPIPE partway through its ~300 KB of output, and with
# `pipefail` set that reads as a failed check on a DMG that is in fact perfectly iconed.
ICNS_DUMP="$(DeRez -only icns "$OUT" 2>/dev/null || true)"
[[ "$ICNS_DUMP" == *"data 'icns'"* ]] ||
    { echo "No icns resource on $OUT — Finder would show a generic disk icon." >&2; exit 1; }

echo "Built: $OUT  ($(du -h "$OUT" | cut -f1))"
echo "Note: the file icon rides in a resource fork. Finder copies, AirDrop and .zip keep"
echo "  it; an HTTP download (GitHub Releases) strips it, so the recipient sees the"
echo "  generic disk icon until they mount it."
