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
APP="$OUT/Flow.app"

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
    codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" \
        --entitlements "$ROOT/Resources/Flow.entitlements" \
        "$APP"
else
    echo "Ad-hoc signing (run scripts/setup_signing.sh for persistent permissions)..."
    codesign --force --deep --sign - \
        --entitlements "$ROOT/Resources/Flow.entitlements" \
        "$APP"
fi

echo "Built: $APP"
