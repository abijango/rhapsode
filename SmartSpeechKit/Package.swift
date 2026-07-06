// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartSpeechKit",
    platforms: [.iOS(.v17), .macOS(.v14)],   // match Rhapsode's deployment targets
    products: [
        .library(name: "SmartSpeechKit", targets: ["SmartSpeechKit"]),
    ],
    targets: [
        .target(name: "SmartSpeechKit"),          // Accelerate + AVFoundation are system frameworks
        .testTarget(name: "SmartSpeechKitTests", dependencies: ["SmartSpeechKit"]),
    ]
)
