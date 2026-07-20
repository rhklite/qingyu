#!/bin/bash
# Builds Qingyu.app directly with swiftc.
#
# We bypass `swift build` because some Command Line Tools installs ship a broken
# SwiftPM ManifestAPI (link error on PackageDescription.Package.init). Package.swift
# is kept for environments with a working toolchain; this script is the reliable path.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WHISPER="$ROOT/third_party/whisper.cpp"
BUILD="$WHISPER/build"
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

if [[ ! -f "$BUILD/src/libwhisper.a" ]]; then
    echo "whisper.cpp not built. Run scripts/build_whisper.sh first." >&2
    exit 1
fi

SDK="$(xcrun --show-sdk-path)"
mkdir -p "$OUT"

STATIC_LIBS=(
    "$BUILD/src/libwhisper.a"
    "$BUILD/ggml/src/libggml.a"
    "$BUILD/ggml/src/libggml-cpu.a"
    "$BUILD/ggml/src/ggml-metal/libggml-metal.a"
    "$BUILD/ggml/src/ggml-blas/libggml-blas.a"
    "$BUILD/ggml/src/libggml-base.a"
)

echo "Compiling Qingyu..."
swiftc \
    -O \
    -parse-as-library \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK" \
    -Xcc -I"$ROOT/Sources/CWhisper" \
    -Xcc -I"$ROOT/Sources/CWhisper/include" \
    -Xcc -fmodule-map-file="$ROOT/Sources/CWhisper/module.modulemap" \
    "$ROOT"/Sources/Qingyu/*.swift \
    "${STATIC_LIBS[@]}" \
    -lc++ \
    -framework Metal -framework MetalKit -framework Accelerate \
    -framework AppKit -framework AVFoundation -framework CoreGraphics \
    -framework ApplicationServices \
    -o "$OUT/Qingyu"

echo "Assembling $APP..."
# A running instance holds the bundle open; if we rm/sign over it, codesign fails
# with "resource fork ... not allowed". Stop it and wait briefly for the lock to drop.
pkill -x Qingyu 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Qingyu >/dev/null || break; sleep 0.3; done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Qingyu" "$APP/Contents/MacOS/Qingyu"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

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
signed=false
for _ in 1 2 3 4 5; do
    xattr -cr "$APP" 2>/dev/null || true
    if codesign --force --deep "${SIGN_ARGS[@]}" \
        --entitlements "$ROOT/Resources/Qingyu.entitlements" "$APP" 2>/tmp/qingyu-codesign.err; then
        signed=true; break
    fi
    sleep 0.4
done
if [[ "$signed" != true ]]; then
    echo "codesign failed after retries:" >&2; cat /tmp/qingyu-codesign.err >&2; exit 1
fi
codesign --verify --strict "$APP" || { echo "signature verify failed" >&2; exit 1; }

echo "Built: $APP"
