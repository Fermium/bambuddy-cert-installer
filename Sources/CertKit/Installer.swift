import Darwin
import Foundation

/// Adds the certificate to a slicer's file, then re-signs the app so macOS still opens it. Before its first
/// change to a slicer it keeps a snapshot of everything re-signing touches, so Undo, or any failure, puts the
/// slicer back exactly as it was, original signature included.
public struct Installer: Sendable {
    public struct State: Equatable, Sendable {
        public var trusted: Bool
        public var signatureValid: Bool
        public var canUndo: Bool
    }

    public let backups: URL

    public init(backups: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Bambuddy Cert Installer/Backups")) {
        self.backups = backups
    }

    /// Slow: checking the signature reads the whole app. Call it off the main thread.
    public func state(of slicer: Slicer, for cert: CACertificate?) -> State {
        State(trusted: cert.map { contains(slicer, $0) } ?? false, signatureValid: Self.verify(slicer.app) == nil, canUndo: snapshot(of: slicer) != nil)
    }

    public func contains(_ slicer: Slicer, _ cert: CACertificate) -> Bool {
        guard let text = try? String(contentsOf: slicer.certFile, encoding: .utf8) else { return false }
        return PEM.certificates(in: text).contains(cert.der)
    }

    /// Returns false when it was already there. The caller checks the slicer isn't running.
    @discardableResult
    public func install(_ cert: CACertificate, into slicer: Slicer) throws -> Bool {
        let text = try String(contentsOf: slicer.certFile, encoding: .utf8)
        guard !PEM.certificates(in: text).contains(cert.der) else { return false }
        let saved = try snapshot(of: slicer) ?? takeSnapshot(of: slicer)
        let added = text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + cert.pem
        do {
            try Data(added.utf8).write(to: slicer.certFile, options: .atomic)
        } catch {
            throw CertError.noPermission(slicer.name)
        }
        if let failure = Self.sign(slicer.app) ?? Self.verify(slicer.app) {
            try? restore(slicer, from: saved)
            throw CertError.signingFailed(failure)
        }
        // Gatekeeper checks a downloaded app against its notarization, which the new signature doesn't
        // have, and would refuse to open it. You opened it before, so its download flag can go.
        removexattr(slicer.app.path, "com.apple.quarantine", 0)
        return true
    }

    /// Puts the slicer back as it was before this app first changed it.
    public func undo(_ slicer: Slicer) throws {
        guard let saved = snapshot(of: slicer) else { throw CertError.nothingToUndo }
        try restore(slicer, from: saved)
        if let failure = Self.verify(slicer.app) { throw CertError.signingFailed(failure) }
        try FileManager.default.removeItem(at: saved)
    }

    // MARK: Snapshots

    /// What re-signing changes: the certificate file, the main program, which holds the signature, and the
    /// seal of the app's files.
    private func parts(of slicer: Slicer) -> [String] {
        let info = NSDictionary(contentsOf: slicer.app.appending(path: "Contents/Info.plist"))
        let program = info?["CFBundleExecutable"] as? String ?? ""
        return ["Contents/Resources/cert/printer.cer", "Contents/MacOS/\(program)", "Contents/_CodeSignature"]
    }

    /// The version a snapshot belongs to. An update replaces the app, and an old snapshot with it.
    private func version(of slicer: Slicer) -> String {
        let info = NSDictionary(contentsOf: slicer.app.appending(path: "Contents/Info.plist"))
        return "\(info?["CFBundleShortVersionString"] as? String ?? "")+\(info?["CFBundleVersion"] as? String ?? "")"
    }

    private func folder(_ slicer: Slicer) -> URL { backups.appending(path: slicer.bundleID, directoryHint: .isDirectory) }

    /// The snapshot for this version of the slicer, if there is one.
    func snapshot(of slicer: Slicer) -> URL? {
        let dir = folder(slicer)
        guard (try? String(contentsOf: dir.appending(path: "version"), encoding: .utf8)) == version(of: slicer) else { return nil }
        return dir
    }

    private func takeSnapshot(of slicer: Slicer) throws -> URL {
        let dir = folder(slicer)
        try? FileManager.default.removeItem(at: dir)
        for part in parts(of: slicer) {
            let target = dir.appending(path: part)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A clone on APFS: instant, and it only takes space once re-signing rewrites the original.
            try FileManager.default.copyItem(at: slicer.app.appending(path: part), to: target)
        }
        try version(of: slicer).write(to: dir.appending(path: "version"), atomically: true, encoding: .utf8)
        return dir
    }

    private func restore(_ slicer: Slicer, from saved: URL) throws {
        for part in parts(of: slicer) {
            let target = slicer.app.appending(path: part), staged = target.deletingLastPathComponent().appending(path: ".restoring-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: saved.appending(path: part), to: staged)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        }
    }

    // MARK: Signing

    /// Ad hoc, keeping the app's entitlements and hardened runtime. Only the app's own seal changes, so the
    /// frameworks inside keep their signatures. Nil when it worked, or codesign's message.
    static func sign(_ app: URL) -> String? {
        codesign(["--force", "--sign", "-", "--preserve-metadata=entitlements,flags,runtime", app.path])
    }

    static func verify(_ app: URL) -> String? {
        codesign(["--verify", "--strict", "--deep", app.path])
    }

    private static func codesign(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = arguments
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        do { try process.run() } catch { return "\(error)" }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return text.split(separator: "\n").last.map { String($0).replacingOccurrences(of: app(from: arguments), with: "") }
            ?? "codesign failed"
    }

    private static func app(from arguments: [String]) -> String { (arguments.last ?? "") + ": " }
}
