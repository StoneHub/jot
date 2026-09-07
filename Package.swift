// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PorchCore", platforms: [.macOS(.v14)], products: [
    .library(name: "PorchCore", targets: ["PorchCore"]),
    .executable(name: "porch", targets: ["PorchCLI"])
], targets: [
    .target(name: "PorchCore", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "PorchCLI", dependencies: ["PorchCore"]),
    .testTarget(name: "PorchCoreTests", dependencies: ["PorchCore"])
])
