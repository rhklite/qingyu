#!/bin/bash
# Builds whisper.cpp as static libraries with the Metal backend embedded
# (no runtime .metallib needed). Run once before scripts/build.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
W="$(pwd)/third_party/whisper.cpp"

if [[ ! -f "$W/CMakeLists.txt" ]]; then
    echo "third_party/whisper.cpp is missing. Clone it:" >&2
    echo "  git clone --depth 1 https://github.com/ggml-org/whisper.cpp third_party/whisper.cpp" >&2
    exit 1
fi

rm -rf "$W/build"
cmake -B "$W/build" -S "$W" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_METAL_USE_BF16=ON \
    -DGGML_BLAS=ON \
    -DGGML_OPENMP=OFF

cmake --build "$W/build" -j

# Refresh the headers exposed to Swift.
CW="$(pwd)/Sources/CWhisper/include"
mkdir -p "$CW"
cp "$W/include/whisper.h" "$CW/"
cp "$W/ggml/include/"*.h "$CW/"

echo "whisper.cpp static libs built under $W/build"
