// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayRecording",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayRecording", targets: ["PixelbayRecording"])
    ],
    dependencies: [
        .package(path: "../PixelbayCore"),
        .package(path: "../PixelbayCapture")
    ],
    targets: [
        .target(
            name: "PixelbayRecording",
            dependencies: ["PixelbayCore", "PixelbayCapture"]
        ),
        .testTarget(
            name: "PixelbayRecordingTests",
            dependencies: ["PixelbayRecording", "PixelbayCore", "PixelbayCapture"]
        )
    ]
)
