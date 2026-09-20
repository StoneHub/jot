// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "JotCore", platforms: [.macOS(.v14)], products: [
    .library(name: "JotCore", targets: ["JotCore"]),
    .executable(name: "jot", targets: ["JotCLI"])
], dependencies: [
    .package(url: "https://github.com/StoneHub/apple-fm-swift.git", revision: "737fac9e7147403f2777e0901f02452e8fc25ae7")
], targets: [
    .target(name: "JotCore", dependencies: [.product(name: "AppleFM", package: "apple-fm-swift")],
            linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "JotCLI", dependencies: ["JotCore"]),
    .testTarget(name: "JotCoreTests", dependencies: ["JotCore"])
])
