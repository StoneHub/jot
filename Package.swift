// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "JotCore", platforms: [.macOS(.v14)], products: [
    .library(name: "JotCore", targets: ["JotCore"]),
    .executable(name: "jot", targets: ["JotCLI"]),
    .executable(name: "jot-suggestion-eval", targets: ["JotSuggestionEvaluation"])
], dependencies: [
    .package(url: "https://github.com/StoneHub/apple-fm-swift.git", revision: "5b937241b0236f892af28588e75a78dd557acf21")
], targets: [
    .target(name: "JotCore", dependencies: [.product(name: "AppleFM", package: "apple-fm-swift")],
            linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "JotCLI", dependencies: ["JotCore"]),
    .executableTarget(name: "JotSuggestionEvaluation", dependencies: ["JotCore"]),
    .testTarget(name: "JotCoreTests", dependencies: ["JotCore"]),
    .testTarget(name: "JotSuggestionEvaluationTests", dependencies: ["JotSuggestionEvaluation"])
], swiftLanguageModes: [.v6])
