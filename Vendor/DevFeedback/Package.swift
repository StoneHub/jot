// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevFeedback",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DevFeedback", targets: ["DevFeedback"])],
    targets: [
        .target(name: "DevFeedback"),
        .testTarget(name: "DevFeedbackTests", dependencies: ["DevFeedback"])
    ]
)
