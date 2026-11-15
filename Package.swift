// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BambuddyCertInstaller",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Updates, from the feed at fermium.ltd.uk/apps/bambuddy-cert-installer/appcast.xml, checked with the EdDSA key.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Finding Bambuddy, reading its certificate, and adding it to the slicers. No UI.
        .target(name: "CertKit"),
        .executableTarget(name: "BambuddyCertInstaller", dependencies: ["CertKit", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "CertKitTests", dependencies: ["CertKit"]),
    ]
)
