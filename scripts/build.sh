#!/bin/bash
# Builds Flow.app directly with swiftc.
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
# Assemble the .app OUTSIDE the project when the project sits in a cloud-synced folder
# (iCloud/Dropbox/etc.). Their file-provider re-tags .app bundles with com.apple.FinderInfo
# faster than we can strip it, which makes codesign fail with "resource fork ... not
# allowed". ~/Library/Application Support is never synced. Override with FLOW_APP_DIR.
APP_DIR="${FLOW_APP_DIR:-$HOME/Library/Application Support/Flow}"
APP="$APP_DIR/Flow.app"
mkdir -p "$APP_DIR"

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

echo "Compiling Flow..."
swiftc \
    -O \
    -parse-as-library \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK" \
    -Xcc -I"$ROOT/Sources/CWhisper" \
    -Xcc -I"$ROOT/Sources/CWhisper/include" \
    -Xcc -fmodule-map-file="$ROOT/Sources/CWhisper/module.modulemap" \
    "$ROOT"/Sources/Flow/*.swift \
    "${STATIC_LIBS[@]}" \
    -lc++ \
    -framework Metal -framework MetalKit -framework Accelerate \
    -framework AppKit -framework AVFoundation -framework CoreGraphics \
    -framework ApplicationServices \
    -o "$OUT/Flow"

echo "Assembling $APP..."
# A running instance holds the bundle open; if we rm/sign over it, codesign fails
# with "resource fork ... not allowed". Stop it and wait briefly for the lock to drop.
pkill -x Flow 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Flow >/dev/null || break; sleep 0.3; done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Flow" "$APP/Contents/MacOS/Flow"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Prefer the stable self-signed identity (scripts/setup_signing.sh) so TCC
# permissions survive rebuilds. Fall back to ad-hoc if it isn't set up.
SIGN_ID="Flow Local Dev"
SIGN_KC="$HOME/Library/Keychains/flow-signing.keychain-db"
if security find-identity "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "Signing with stable identity '$SIGN_ID'..."
    security unlock-keychain -p "flow-local-signing" "$SIGN_KC" 2>/dev/null || true
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
        --entitlements "$ROOT/Resources/Flow.entitlements" "$APP" 2>/tmp/flow-codesign.err; then
        signed=true; break
    fi
    sleep 0.4
done
if [[ "$signed" != true ]]; then
    echo "codesign failed after retries:" >&2; cat /tmp/flow-codesign.err >&2; exit 1
fi
codesign --verify --strict "$APP" || { echo "signature verify failed" >&2; exit 1; }

echo "Built: $APP"
