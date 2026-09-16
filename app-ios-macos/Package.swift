// swift-tools-version: 5.9
import PackageDescription

// Small, framework-free camera rules can run in CI without HomeKit hardware.
// The app also compiles these sources directly in its Xcode target.
let package = Package(
    name: "HomecastCameraCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CameraCore", path: "Sources/CameraCore"),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore"], path: "Tests/CameraCoreTests"),
    ]
)
