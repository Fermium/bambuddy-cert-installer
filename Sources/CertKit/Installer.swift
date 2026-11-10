import Darwin
import Foundation

/// Adds the certificate to a slicer's file, then re-signs the app so macOS still opens it. Every change keeps a
/// backup, and any failure puts the file back.
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
        State(trusted: cert.map { contains(slicer, $0) } ?? false, signatureValid: Self.verify(slicer.app) == nil, canUndo: latestBackup(slicer) != nil)
    }

    public func contains(_ slicer: Slicer, _ cert: CACertificate) -> Bool {
        guard let text = try? String(contentsOf: slicer.certFile, encoding: .utf8) else { return false }
        return PEM.certificates(in: text).contains(cert.der)
    }

    /// Returns false when it was already there. The caller checks the slicer isn't running.
    @discardableResult
    public func install(_ cert: CACertificate, into slicer: Slicer) throws -> Bool {
        let original = try Data(contentsOf: slicer.certFile)
        let text = String(decoding: original, as: UTF8.self)
        guard !PEM.certificates(in: text).contains(cert.der) else { return false }
        try backUp(original, of: slicer)
        let added = text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + cert.pem
        try replace(slicer, with: Data(added.utf8), restoring: original)
        return true
    }

    /// Puts back the file as it was before the last change.
    public func undo(_ slicer: Slicer) throws {
        guard let backup = latestBackup(slicer) else { throw CertError.nothingToUndo }
        let current = try Data(contentsOf: slicer.certFile)
        try replace(slicer, with: try Data(contentsOf: backup), restoring: current)
        try FileManager.default.removeItem(at: backup)
    }

    private func replace(_ slicer: Slicer, with data: Data, restoring previous: Data) throws {
        do {
            try data.write(to: slicer.certFile, options: .atomic)
        } catch {
            throw CertError.noPermission(slicer.name)
        }
        if let failure = Self.sign(slicer.app) ?? Self.verify(slicer.app) {
            try? previous.write(to: slicer.certFile, options: .atomic)
            _ = Self.sign(slicer.app)
            throw CertError.signingFailed(failure)
        }
        // Gatekeeper checks a downloaded app against its notarization, which the new signature doesn't
        // have, and would refuse to open it. You opened it before, so its download flag can go.
        removexattr(slicer.app.path, "com.apple.quarantine", 0)
    }

    // MARK: Backups

    private func folder(_ slicer: Slicer) -> URL { backups.appending(path: slicer.bundleID, directoryHint: .isDirectory) }

    private func backUp(_ data: Data, of slicer: Slicer) throws {
        let dir = folder(slicer)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try data.write(to: dir.appending(path: "printer-\(stamp).cer"), options: .atomic)
    }

    func latestBackup(_ slicer: Slicer) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder(slicer), includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "cer" }.max { $0.lastPathComponent < $1.lastPathComponent }
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
