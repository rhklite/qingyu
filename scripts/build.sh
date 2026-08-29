#!/bin/bash
# Builds Qingyu.app directly with swiftc.
#
# We bypass `swift build` because some Command Line Tools installs ship a broken
# SwiftPM ManifestAPI (link error on PackageDescription.Package.init). Package.swift
# is kept for environments with a working toolchain; this script is the reliable path.
#
# Produces a universal binary from whichever slices scripts/build_whisper.sh left in
# third_party/whisper.cpp/build-<arch> (both by default; QINGYU_ARCHS narrows it).
# The x86_64 slice has no Metal backend — see build_whisper.sh for why.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WHISPER="$ROOT/third_party/whisper.cpp"
OUT="$ROOT/.build"
# Install into /Applications so it's a normal double-click app; fall back to
# ~/Applications if /Applications needs admin. Both live outside iCloud/Dropbox sync,
# so the file-provider "resource fork ... not allowed" codesign failure — which hits
# when the .app sits in a synced folder like ~/Documents — doesn't apply here.
# Override the location with QINGYU_APP_DIR.
APP_DIR="${QINGYU_APP_DIR:-/Applications}"
[ -w "$APP_DIR" ] || APP_DIR="$HOME/Applications"
mkdir -p "$APP_DIR"
APP="$APP_DIR/轻语.app"

# Build every arch that has whisper libs, so a source install that only built arm64
# still works and the DMG build picks up both.
ARCHS=""
for arch in ${QINGYU_ARCHS:-arm64 x86_64}; do
    [[ -f "$WHISPER/build-$arch/src/libwhisper.a" ]] && ARCHS="$ARCHS $arch"
done
if [[ -z "$ARCHS" ]]; then
    echo "whisper.cpp not built. Run scripts/build_whisper.sh first." >&2
    exit 1
fi

SDK="$(xcrun --show-sdk-path)"
# Sparkle ships as a prebuilt universal framework (third_party/Sparkle). It is linked
# against and embedded rather than fetched by SwiftPM, because this script deliberately
# bypasses `swift build` — see the header.
SPARKLE_DIR="$ROOT/third_party/Sparkle"
[[ -d "$SPARKLE_DIR/Sparkle.framework" ]] || {
    echo "Missing $SPARKLE_DIR/Sparkle.framework — the updater cannot be built." >&2; exit 1; }
mkdir -p "$OUT"

SLICES=()
for arch in $ARCHS; do
    BUILD="$WHISPER/build-$arch"
    STATIC_LIBS=(
        "$BUILD/src/libwhisper.a"
        "$BUILD/ggml/src/libggml.a"
        "$BUILD/ggml/src/libggml-cpu.a"
    )
    # Only the arm64 build has a Metal backend.
    [[ -f "$BUILD/ggml/src/ggml-metal/libggml-metal.a" ]] &&
        STATIC_LIBS+=("$BUILD/ggml/src/ggml-metal/libggml-metal.a")
    STATIC_LIBS+=(
        "$BUILD/ggml/src/ggml-blas/libggml-blas.a"
        "$BUILD/ggml/src/libggml-base.a"
    )

    echo "Compiling Qingyu ($arch)..."
    swiftc \
        -O \
        -parse-as-library \
        -target "$arch-apple-macosx13.0" \
        -sdk "$SDK" \
        -Xcc -I"$ROOT/Sources/CWhisper" \
        -Xcc -I"$ROOT/Sources/CWhisper/include" \
        -Xcc -fmodule-map-file="$ROOT/Sources/CWhisper/module.modulemap" \
        -F "$SPARKLE_DIR" \
        -framework Sparkle \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        "$ROOT"/Sources/Qingyu/*.swift \
        "${STATIC_LIBS[@]}" \
        -lc++ \
        -framework Metal -framework MetalKit -framework Accelerate \
        -framework AppKit -framework AVFoundation -framework CoreGraphics \
        -framework ApplicationServices \
        -o "$OUT/Qingyu-$arch"
    SLICES+=("$OUT/Qingyu-$arch")
done

if [[ ${#SLICES[@]} -gt 1 ]]; then
    echo "Merging into a universal binary ($ARCHS )..."
    lipo -create "${SLICES[@]}" -output "$OUT/Qingyu"
else
    cp "${SLICES[0]}" "$OUT/Qingyu"
fi

echo "Assembling $APP..."
# A running instance holds the bundle open; if we rm/sign over it, codesign fails
# with "resource fork ... not allowed". Stop it and wait briefly for the lock to drop.
pkill -x Qingyu 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Qingyu >/dev/null || break; sleep 0.3; done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Qingyu" "$APP/Contents/MacOS/Qingyu"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Menu-bar mark: idle is a template image, the listening cut keeps its amber dot.
cp "$ROOT"/Resources/icons/*.png "$APP/Contents/Resources/"

# Sparkle has to travel inside the bundle for @rpath to resolve at launch.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"

# Prefer the stable self-signed identity (scripts/setup_signing.sh) so TCC
# permissions survive rebuilds. Fall back to ad-hoc if it isn't set up.
SIGN_ID="Qingyu Local Dev"
SIGN_KC="$HOME/Library/Keychains/qingyu-signing.keychain-db"
if security find-identity "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "Signing with stable identity '$SIGN_ID'..."
    security unlock-keychain -p "qingyu-local-signing" "$SIGN_KC" 2>/dev/null || true
    SIGN_ARGS=(--sign "$SIGN_ID" --keychain "$SIGN_KC")
else
    echo "Ad-hoc signing (run scripts/setup_signing.sh for persistent permissions)..."
    SIGN_ARGS=(--sign -)
fi

# macOS re-attaches xattrs (com.apple.provenance / Finder info) to freshly written
# files, and this macOS's codesign aborts on them with "resource fork ... not
# allowed". Stripping can race the re-add, so strip-and-sign in a short retry loop.
# Sign inner-out. `--deep` is documented as unreliable and, with a framework that
# carries its own XPC services and helper apps, it signs them in the wrong order and
# produces a bundle that launches on this Mac and is rejected on the next one. The
# framework's nested code has to be signed before the framework, and the framework
# before the app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
NESTED=(
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    "$SPARKLE_FW/Versions/B/Updater.app"
    "$SPARKLE_FW/Versions/B/Autoupdate"
)
signed=false
for _ in 1 2 3 4 5; do
    xattr -cr "$APP" 2>/dev/null || true
    ok=true
    for item in "${NESTED[@]}"; do
        [[ -e "$item" ]] || continue
        codesign --force "${SIGN_ARGS[@]}" "$item" 2>/tmp/qingyu-codesign.err || { ok=false; break; }
    done
    if [[ "$ok" == true ]] &&
       codesign --force "${SIGN_ARGS[@]}" "$SPARKLE_FW" 2>/tmp/qingyu-codesign.err &&
       codesign --force "${SIGN_ARGS[@]}" \
        --entitlements "$ROOT/Resources/Qingyu.entitlements" "$APP" 2>/tmp/qingyu-codesign.err; then
        signed=true; break
    fi
    sleep 0.4
done
if [[ "$signed" != true ]]; then
    echo "codesign failed after retries:" >&2; cat /tmp/qingyu-codesign.err >&2; exit 1
fi
codesign --verify --strict --deep "$APP" || { echo "signature verify failed" >&2; exit 1; }

echo "Built: $APP  ($(lipo -archs "$APP/Contents/MacOS/Qingyu"))"
