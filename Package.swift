// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cadenza",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "CadenzaCore", targets: ["CadenzaCore"])
    ],
    targets: [
        .target(
            name: "CadenzaCore"
        ),
        .executableTarget(
            name: "CadenzaApp",
            dependencies: ["CadenzaCore"]
        ),
        // Plain assertion-based checks runnable with `swift run CadenzaCoreChecks`.
        // Command Line Tools cannot run XCTest or Swift Testing; convert to a
        // proper testTarget once a full Xcode install is available.
        .executableTarget(
            name: "CadenzaCoreChecks",
            dependencies: ["CadenzaCore"]
        )
    ]
)
