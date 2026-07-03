// swift-tools-version: 5.10
// M0 spike harness (docs/native-swift-path.md) — NOT the app target.
// Benchmarks FluidAudio (Parakeet on the Neural Engine) against the Python
// stack's numbers; mlx-swift cleanup benchmark lands once Xcode (Metal
// toolchain) is installed.
import PackageDescription

let package = Package(
    name: "pomvox-native",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-huggingface-mlx.git", from: "0.2.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx.git", from: "0.3.0"),
        // Transitive pin: swift-tokenizers 0.6+ made encode/decode throwing,
        // which swift-tokenizers-mlx 0.3.0 doesn't compile against yet.
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git", "0.5.0"..<"0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "pomvox-bench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // Separate target: needs the Metal toolchain (full Xcode), unlike the
        // STT harness which builds with Command Line Tools alone.
        .executableTarget(
            name: "pomvox-bench-llm",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLMHuggingFace", package: "swift-huggingface-mlx"),
                .product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx"),
            ]
        ),
    ]
)
