// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MeetingSTTApp",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "MeetingSTTApp", targets: ["MeetingSTTApp"]),
    ],
    targets: [
        .executableTarget(name: "MeetingSTTApp"),
    ]
)
