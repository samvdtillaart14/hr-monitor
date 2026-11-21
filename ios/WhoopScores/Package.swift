// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhoopScores",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "WhoopScores", targets: ["WhoopScores"])],
    targets: [
        .target(name: "WhoopScores"),
        .testTarget(name: "WhoopScoresTests", dependencies: ["WhoopScores"]),
    ]
)
