import AppKit
import Foundation

/// A slicer that trusts printers through the certificate file inside its own app.
public struct Slicer: Identifiable, Hashable, Sendable {
    public let name: String
    public let bundleID: String
    public let app: URL

    public init(name: String, bundleID: String, app: URL) {
        self.name = name
        self.bundleID = bundleID
        self.app = app
    }

    public var id: String { app.path }
    public var certFile: URL { app.appending(path: "Contents/Resources/cert/printer.cer") }

    /// OrcaSlicer changed its bundle ID once; both are listed.
    static let known = [
        ("OrcaSlicer", "com.orcaslicer.OrcaSlicer"),
        ("OrcaSlicer", "com.softfever3d.orca-slicer"),
        ("Bambu Studio", "com.bambulab.bambu-studio"),
    ]

    /// The Applications folders, read directly: right after an update, macOS's app database can still miss
    /// the new copy for a while.
    static func inApplicationFolders() -> [(String, URL)] {
        let folders = [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
                .compactMap { app in (NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleIdentifier"] as? String).map { ($0, app) } }
        }
    }

    /// Every copy that has a certificate file: in the Applications folders, and anywhere else macOS knows of.
    @MainActor
    public static func installed() -> [Slicer] {
        var found: [Slicer] = []
        let direct = inApplicationFolders()
        for (name, bundleID) in known {
            let urls = direct.filter { $0.0 == bundleID }.map(\.1) + NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            for url in urls {
                let slicer = Slicer(name: name, bundleID: bundleID, app: url.standardizedFileURL)
                // Skip copies inside other bundles, in the Trash, or already listed.
                guard FileManager.default.fileExists(atPath: slicer.certFile.path), !url.path.contains("/.Trash/"),
                      !found.contains(where: { $0.app == slicer.app }) else { continue }
                found.append(slicer)
            }
        }
        // Several copies of one slicer get their folder in the name.
        return found.map { s in
            found.filter({ $0.name == s.name }).count > 1 ? Slicer(name: "\(s.name) (\(s.app.deletingLastPathComponent().lastPathComponent))", bundleID: s.bundleID, app: s.app) : s
        }
    }

    @MainActor
    public var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.bundleURL?.standardizedFileURL == app }
    }
}
