// swift-tools-version:5.9
import PackageDescription
import Foundation

// Absolute path to this package (Package.swift lives at the package root).
// SwiftPM builds for the host arch only; scripts/build.sh is what produces the
// universal binary. Intel builds have no Metal backend — see scripts/build_whisper.sh.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
#if arch(arm64)
let hostArch = "arm64"
let metalLibs = ["/ggml/src/ggml-metal/libggml-metal.a"]
#else
let hostArch = "x86_64"
let metalLibs: [String] = []
#endif
let buildDir = root + "/third_party/whisper.cpp/build-" + hostArch

// The static libraries produced by `scripts/build_whisper.sh`.
// Listed most-dependent first so ld64 resolves symbols cleanly.
let staticLibs = ([
    "/src/libwhisper.a",
    "/ggml/src/libggml.a",
    "/ggml/src/libggml-cpu.a",
] + metalLibs + [
    "/ggml/src/ggml-blas/libggml-blas.a",
    "/ggml/src/libggml-base.a",
]).map { buildDir + $0 }

let package = Package(
    name: "Qingyu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Qingyu", targets: ["Qingyu"]),
    ],
    targets: [
        // Header-only module exposing whisper.cpp's C API to Swift.
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .executableTarget(
            name: "Qingyu",
            dependencies: ["CWhisper"],
            linkerSettings: [
                .unsafeFlags(staticLibs),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
