import AppKit
import CertKit
import Foundation
import OSLog
import ServiceManagement

let log = Logger(subsystem: "com.fermium.bambuddy-cert-installer", category: "app")

/// What the popover and Settings show: Bambuddy, its certificate, and each slicer.
@MainActor
final class Model: ObservableObject {
    struct Row: Identifiable {
        var slicer: Slicer
        var state: Installer.State?
        var running = false
        var version: String
        var id: String { slicer.id }
    }

    @Published private(set) var bambuddy: Bambuddy?
    @Published private(set) var cert: CACertificate?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var checking = false
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var lastCheck: Date?
    @Published var message: String?
    /// What it did by itself, such as fixing a slicer after an update.
    @Published private(set) var note: String?

    /// The fingerprint you confirmed. Anything else is refused until you confirm it again.
    @Published private(set) var trusted = UserDefaults.standard.string(forKey: Keys.trusted)
    /// An address you typed. Empty means find it.
    @Published var address = UserDefaults.standard.string(forKey: Keys.address) ?? "" {
        didSet { UserDefaults.standard.set(address.trimmingCharacters(in: .whitespaces), forKey: Keys.address) }
    }
    @Published var fixAfterUpdates = UserDefaults.standard.object(forKey: Keys.fix) as? Bool ?? true {
        didSet { UserDefaults.standard.set(fixAfterUpdates, forKey: Keys.fix) }
    }

    private enum Keys {
        static let trusted = "trustedFingerprint", address = "bambuddyAddress", fix = "fixAfterUpdates", managed = "managedSlicers"
    }

    /// Slicers you added the certificate to, by bundle ID: these get it back after an update.
    private var managed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.managed) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Keys.managed) }
    }

    let installer = Installer()
    private var timer: Timer?
    private var watcher: FolderWatcher?
    private var pending: Task<Void, Never>?

    var needsConfirming: Bool { cert != nil && trusted == nil }
    var changed: Bool { cert != nil && trusted != nil && cert?.fingerprint != trusted }
    var ready: Bool { cert != nil && trusted == cert?.fingerprint }
    var allGood: Bool { ready && !rows.isEmpty && rows.allSatisfy { $0.state?.trusted == true && $0.state?.signatureValid == true } }

    init() {
        Task {
            await refresh()
            // The first look can run while macOS is still asking about the local network.
            for wait in [3, 10, 30] where cert == nil {
                try? await Task.sleep(for: .seconds(wait))
                await refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.soon() }
        }
        // A slicer that just quit may have updated itself, and can now be changed.
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let id = app?.bundleIdentifier, self?.rows.contains(where: { $0.slicer.bundleID == id }) == true { self?.soon() }
            }
        }
        watchApplications()
    }

    // MARK: Checking

    /// A check a few seconds from now, so an update or a quit can finish first. Calls in between merge.
    func soon(_ seconds: Double = 5) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { await refresh() }
        }
    }

    func refresh() async {
        guard !checking else { log.info("check skipped: one is running"); return }
        log.info("checking")
        checking = true
        defer { checking = false }
        let typed = address.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            do {
                guard let server = Self.server(from: typed) else { throw CertError.notBambuddy(typed) }
                cert = try await server.certificate()
                bambuddy = server
                message = nil
            } catch {
                bambuddy = nil
                cert = nil
                message = "\(error)"
            }
        } else if let (server, found) = await Bambuddy.find() {
            bambuddy = server
            cert = found
            message = nil
        } else {
            bambuddy = nil
            cert = nil
            message = "Bambuddy wasn't found on this network. Turn on its Virtual Printer, or type its address in Settings."
        }
        await reloadSlicers()
        if fixAfterUpdates { await fixUpdated() }
        lastCheck = Date()
    }

    func reloadSlicers() async {
        let slicers = Slicer.installed()
        let installer = installer, cert = cert
        let states = await Task.detached { slicers.map { installer.state(of: $0, for: cert) } }.value
        rows = zip(slicers, states).map { slicer, state in
            let info = Bundle(url: slicer.app)?.infoDictionary
            return Row(slicer: slicer, state: state, running: slicer.isRunning, version: info?["CFBundleShortVersionString"] as? String ?? "")
        }
    }

    private func fixUpdated() async {
        guard ready, let cert else { return }
        let slicers = rows.map(\.slicer), managed = managed, installer = installer
        let running = Set(rows.filter { $0.slicer.isRunning }.map(\.id))
        guard slicers.contains(where: { managed.contains($0.bundleID) }) else { return }
        let result = await Task.detached { installer.fixUpdated(slicers, cert: cert, managed: managed, running: running) }.value
        log.info("after-update check of \(slicers.count) slicers: fixed \(result.fixed.map(\.name), privacy: .public), failed \(result.failed.count)")
        if !result.fixed.isEmpty {
            note = "Added the certificate again to \(result.fixed.map(\.name).joined(separator: " and ")) after an update."
            await reloadSlicers()
        }
        if let (slicer, error) = result.failed.first { message = "\(slicer.name) updated, and adding the certificate again failed: \(error)" }
    }

    /// An update replaces the slicer, so watch where slicers live. Anything changing there leads to one check
    /// shortly after it settles, including this app's own changes, which then find nothing to do.
    private func watchApplications() {
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path]
        watcher = FolderWatcher(folders) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.busy.isEmpty else { return }
                log.info("Applications changed")
                self.soon(10)
            }
        }
    }

    // MARK: Actions

    func trust() {
        guard let cert else { return }
        trusted = cert.fingerprint
        UserDefaults.standard.set(cert.fingerprint, forKey: Keys.trusted)
    }

    func forgetTrust() {
        trusted = nil
        UserDefaults.standard.removeObject(forKey: Keys.trusted)
    }

    func add(_ row: Row) {
        guard ready, let cert else { return }
        run(row) { installer, slicer in try installer.install(cert, into: slicer) }
        managed.insert(row.slicer.bundleID)
    }

    func undo(_ row: Row) {
        run(row) { installer, slicer in try installer.undo(slicer) }
        managed.remove(row.slicer.bundleID)
    }

    private func run(_ row: Row, _ action: @escaping @Sendable (Installer, Slicer) throws -> Void) {
        if row.slicer.isRunning {
            message = "\(CertError.slicerRunning(row.slicer.name))"
            return
        }
        busy.insert(row.id)
        message = nil
        note = nil
        let installer = installer, slicer = row.slicer
        Task {
            do {
                try await Task.detached { try action(installer, slicer) }.value
            } catch {
                message = "\(error)"
            }
            // The spinner stays until the row shows the result.
            await reloadSlicers()
            busy.remove(row.id)
        }
    }

    // MARK: Open at login

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = "macOS didn't change Open at Login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    // MARK: Backups

    var backupSize: String {
        let files = FileManager.default.enumerator(at: installer.backups, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total == 0 ? "None" : ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    func showBackups() {
        try? FileManager.default.createDirectory(at: installer.backups, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([installer.backups])
    }

    /// "printers.lan", "192.168.1.50:8000" or a full URL. A bare name gets Bambuddy's usual port.
    static func server(from text: String) -> Bambuddy? {
        guard var parts = URLComponents(string: text.contains("://") ? text : "http://\(text)"), parts.host?.isEmpty == false else { return nil }
        if parts.port == nil, !text.contains("://") { parts.port = Bambuddy.port }
        return parts.url.map { Bambuddy(address: $0) }
    }
}
