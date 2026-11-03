#!/usr/bin/env bash
# Build the eval runner from the app's own WhisperEngine and replay the test set.
#
# Usage: scripts/eval/run_eval.sh [settings] [extra args for the runner]
#   settings: comma-separated, each a "+"-joined list of changes (default: baseline and each change)
#   e.g. scripts/eval/run_eval.sh baseline,natural+zh --limit 20
# Needs the test set first: python3 -I scripts/eval/extract_wispr.py
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
ARCH="$(uname -m)"
BUILD="$ROOT/third_party/whisper.cpp/build-$ARCH"
[[ -f "$BUILD/src/libwhisper.a" ]] || { echo "Run scripts/build_whisper.sh first." >&2; exit 1; }

LIBS=("$BUILD/src/libwhisper.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-cpu.a")
[[ -f "$BUILD/ggml/src/ggml-metal/libggml-metal.a" ]] && LIBS+=("$BUILD/ggml/src/ggml-metal/libggml-metal.a")
LIBS+=("$BUILD/ggml/src/ggml-blas/libggml-blas.a" "$BUILD/ggml/src/libggml-base.a")

mkdir -p .build
echo "Compiling eval runner..."
swiftc -O -parse-as-library \
    -target "$ARCH-apple-macosx13.0" -sdk "$(xcrun --show-sdk-path)" \
    -Xcc -I"$ROOT/Sources/CWhisper" -Xcc -I"$ROOT/Sources/CWhisper/include" \
    -Xcc -fmodule-map-file="$ROOT/Sources/CWhisper/module.modulemap" \
    Tools/eval/main.swift \
    Sources/Qingyu/WhisperEngine.swift Sources/Qingyu/Dictionary.swift \
    Sources/Qingyu/AudioRecorder.swift Sources/Qingyu/AudioDevices.swift \
    "${LIBS[@]}" -lc++ \
    -framework Metal -framework MetalKit -framework Accelerate -framework AppKit \
    -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
    -o .build/qingyu-eval

SETTINGS="${1:-baseline,natural,zh,natural+zh}"
shift || true
OUT="$HOME/.config/qingyu/eval/hyps.jsonl"
.build/qingyu-eval --settings "$SETTINGS" --out "$OUT" "$@" 2>"$HOME/.config/qingyu/eval/runner.log"
python3 -I scripts/eval/score.py "$OUT"
