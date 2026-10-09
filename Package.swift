// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "JotCore", platforms: [.macOS(.v14)], products: [
    .library(name: "JotCore", targets: ["JotCore"]),
    .executable(name: "jot", targets: ["JotCLI"]),
    .executable(name: "jot-suggestion-eval", targets: ["JotSuggestionEvaluation"])
], dependencies: [
    .package(url: "https://github.com/StoneHub/apple-fm-swift.git", revision: "5b937241b0236f892af28588e75a78dd557acf21"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "5c19d5e12320e22bbfb7a1877b089d2665a69add")
], targets: [
    .target(name: "JotCore", dependencies: [.product(name: "AppleFM", package: "apple-fm-swift")],
            linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "JotEngine", dependencies: ["JotCore", .product(name: "FluidAudio", package: "FluidAudio")]),
    .executableTarget(name: "JotCLI", dependencies: ["JotCore"]),
    .executableTarget(name: "JotSuggestionEvaluation", dependencies: ["JotCore"]),
    .testTarget(name: "JotCoreTests", dependencies: ["JotCore"]),
    .testTarget(name: "JotEngineTests", dependencies: ["JotEngine", .product(name: "FluidAudio", package: "FluidAudio")]),
    .testTarget(name: "JotCLITests", dependencies: ["JotCLI"]),
    .testTarget(name: "JotSuggestionEvaluationTests", dependencies: ["JotSuggestionEvaluation"])
], swiftLanguageModes: [.v6])
