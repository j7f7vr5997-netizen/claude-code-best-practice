// swift-tools-version:5.9
import PackageDescription

// Only the pure-Swift motion library is exposed as a SwiftPM product so it can
// be unit-tested cross-platform (`swift test` on macOS or Linux). The iOS-only
// capture layer (AVFoundation, CoreMotion) lives in the main Xcode project.
let package = Package(
    name: "MistyLemur",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "MistyLemurMotion", targets: ["MistyLemurMotion"]),
    ],
    targets: [
        .target(
            name: "MistyLemurMotion",
            path: "MistyLemur",
            sources: [
                "Motion/FastDTW.swift",
                "Motion/Signature.swift",
                "Motion/Matcher.swift",
                "Capture/ZoomCurve.swift",
            ]
        ),
        .testTarget(
            name: "MistyLemurMotionTests",
            dependencies: ["MistyLemurMotion"],
            path: "MistyLemurTests"
        ),
    ]
)
