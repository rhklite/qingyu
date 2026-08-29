#!/bin/bash
# Builds whisper.cpp as static libraries, once per architecture, into
# third_party/whisper.cpp/build-<arch>. Run once before scripts/build.sh.
#
#   QINGYU_ARCHS="arm64 x86_64"   which slices to build (default: both)
#
# arm64  → Metal backend embedded (no runtime .metallib needed).
# x86_64 → CPU only. Metal is useless on Intel Macs: ggml gates matrix ops on
#          MTLGPUFamilyApple7 (ggml-metal-device.m), which no Intel GPU reports, so
#          every matmul would fall back to the CPU anyway. Accelerate/BLAS + AVX2
#          is the real path there.
#
# Neither slice uses -march/-mcpu=native: these libraries get shipped to other
# people's Macs. A native build on an M4 enables i8mm/bf16 that an M1 lacks (SIGILL),
# and on x86 -march=native can't even be evaluated when cross-compiling from arm64.
set -euo pipefail

cd "$(dirname "$0")/.."
W="$(pwd)/third_party/whisper.cpp"
ARCHS="${QINGYU_ARCHS:-arm64 x86_64}"

if [[ ! -f "$W/CMakeLists.txt" ]]; then
    echo "third_party/whisper.cpp is missing. Clone it:" >&2
    echo "  git clone --depth 1 https://github.com/ggml-org/whisper.cpp third_party/whisper.cpp" >&2
    exit 1
fi

for ARCH in $ARCHS; do
    BUILD="$W/build-$ARCH"
    echo "== whisper.cpp: $ARCH =="

    COMMON=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_OSX_ARCHITECTURES="$ARCH"
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
        -DBUILD_SHARED_LIBS=OFF
        -DWHISPER_BUILD_EXAMPLES=OFF
        -DWHISPER_BUILD_TESTS=OFF
        -DWHISPER_BUILD_SERVER=OFF
        -DGGML_BLAS=ON
        -DGGML_OPENMP=OFF
        -DGGML_NATIVE=OFF
    )

    if [[ "$ARCH" == "arm64" ]]; then
        # armv8.2-a+fp16+dotprod is the floor shared by every Apple Silicon Mac (M1+).
        # The heavy math runs on Metal here anyway, so a wider CPU baseline buys nothing.
        ARCH_ARGS=(
            -DGGML_METAL=ON
            -DGGML_METAL_EMBED_LIBRARY=ON
            -DGGML_METAL_USE_BF16=ON
            -DGGML_CPU_ARM_ARCH=armv8.2-a+fp16+dotprod
        )
    else
        # AVX2/FMA/F16C: present on every Intel Mac that can run macOS 13 (Kaby Lake+).
        ARCH_ARGS=(
            -DGGML_METAL=OFF
            -DGGML_AVX=ON
            -DGGML_AVX2=ON
            -DGGML_FMA=ON
            -DGGML_F16C=ON
        )
    fi

    rm -rf "$BUILD"
    cmake -B "$BUILD" -S "$W" "${COMMON[@]}" "${ARCH_ARGS[@]}"
    cmake --build "$BUILD" -j
done

# Refresh the headers exposed to Swift (arch-independent).
CW="$(pwd)/Sources/CWhisper/include"
mkdir -p "$CW"
cp "$W/include/whisper.h" "$CW/"
cp "$W/ggml/include/"*.h "$CW/"

echo
echo "whisper.cpp static libs built for: $ARCHS"
