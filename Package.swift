// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BambuddyCertInstaller",
    platforms: [.macOS(.v15)],
    targets: [
        // Finding Bambuddy, reading its certificate, and adding it to the slicers. No UI.
        .target(name: "CertKit"),
        .executableTarget(name: "BambuddyCertInstaller", dependencies: ["CertKit"]),
        .testTarget(name: "CertKitTests", dependencies: ["CertKit"]),
    ]
)
