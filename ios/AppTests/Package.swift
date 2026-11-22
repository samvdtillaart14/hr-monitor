// swift-tools-version:5.9
import PackageDescription

// Tests voor de app-logica die geen scherm of Bluetooth nodig heeft (parser, sync, opslag, scores per dag, export).
// SwiftPM kan geen bronbestanden buiten deze map gebruiken; ./sync-app-sources.sh kopieert ze uit ../HRMonitor.
let package = Package(
    name: "AppTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../WhoopScores")],
    targets: [
        .target(name: "AppCore", dependencies: [.product(name: "WhoopScores", package: "WhoopScores")]),
        .testTarget(name: "AppCoreTests",
                    dependencies: ["AppCore", .product(name: "WhoopScores", package: "WhoopScores")]),
    ]
)
