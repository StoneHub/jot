// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "JotCore", platforms: [.macOS(.v14)], products: [
    .library(name: "JotCore", targets: ["JotCore"]),
    .executable(name: "jot", targets: ["JotCLI"])
], targets: [
    .target(name: "JotCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "JotCLI", dependencies: ["JotCore"]),
    .testTarget(name: "JotCoreTests", dependencies: ["JotCore"])
])
