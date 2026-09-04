// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "work-buddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WorkBuddy",
            path: "Sources/WorkBuddy"
        ),
        .testTarget(
            name: "WorkBuddyTests",
            dependencies: ["WorkBuddy"],
            path: "Tests/WorkBuddyTests"
        )
    ]
)
