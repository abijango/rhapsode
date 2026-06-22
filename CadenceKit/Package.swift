// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],   // match Rhapsode's deployment targets
    products: [
        .library(name: "CadenceKit", targets: ["CadenceKit"]),
    ],
    targets: [
        .target(name: "CadenceKit"),          // Accelerate + AVFoundation are system frameworks
        .testTarget(name: "CadenceKitTests", dependencies: ["CadenceKit"]),
    ]
)