// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "JotCore", platforms: [.macOS(.v14)], products: [
    .library(name: "JotCore", targets: ["JotCore"]),
    .executable(name: "jot", targets: ["JotCLI"]),
    .executable(name: "jot-suggestion-eval", targets: ["JotSuggestionEvaluation"])
], dependencies: [
    .package(url: "https://github.com/StoneHub/apple-fm-swift.git", revision: "bb7d0e84ef0e7aa04e3f521c61fe20e6dacb7f72")
], targets: [
    .target(name: "JotCore", dependencies: [.product(name: "AppleFM", package: "apple-fm-swift")],
            linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "JotCLI", dependencies: ["JotCore"]),
    .executableTarget(name: "JotSuggestionEvaluation", dependencies: ["JotCore"]),
    .testTarget(name: "JotCoreTests", dependencies: ["JotCore"]),
    .testTarget(name: "JotSuggestionEvaluationTests", dependencies: ["JotSuggestionEvaluation"])
])
