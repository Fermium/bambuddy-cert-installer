import AppKit
import CertKit
import Foundation

/// What the menu shows: Bambuddy, its certificate, and each slicer.
@MainActor
final class Model: ObservableObject {
    struct Row: Identifiable {
        var slicer: Slicer
        var state: Installer.State?
        var running = false
        var id: String { slicer.id }
    }

    @Published private(set) var bambuddy: Bambuddy?
    @Published private(set) var cert: CACertificate?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var checking = false
    @Published private(set) var busy: String?
    @Published var message: String?

    /// The fingerprint you confirmed. Anything else is refused until you confirm it again.
    @Published private(set) var trusted: String? = UserDefaults.standard.string(forKey: "trustedFingerprint")
    /// An address you typed. Empty means search.
    @Published var manualAddress = UserDefaults.standard.string(forKey: "bambuddyAddress") ?? ""

    private let installer = Installer()
    private var timer: Timer?

    var needsConfirming: Bool { cert != nil && trusted == nil }
    var changed: Bool { cert != nil && trusted != nil && cert?.fingerprint != trusted }
    var ready: Bool { cert != nil && trusted == cert?.fingerprint }
    /// Something is wrong or waiting: the menu bar icon shows it.
    var needsAttention: Bool { cert == nil || !ready || rows.contains { $0.state?.trusted == false || $0.state?.signatureValid == false } }

    init() {
        Task { await refresh() }
        // Slicer updates put their original file back, so look again now and then and after waking.
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        if !address.isEmpty {
            let server = Self.server(from: address)
            do {
                guard let server else { throw CertError.notBambuddy(address) }
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
            message = "Bambuddy wasn't found on this network. Turn on its Virtual Printer, or type its address."
        }
        await reloadSlicers()
    }

    func reloadSlicers() async {
        let slicers = Slicer.installed()
        let installer = installer, cert = cert
        let states = await Task.detached { slicers.map { installer.state(of: $0, for: cert) } }.value
        rows = zip(slicers, states).map { Row(slicer: $0, state: $1, running: $0.isRunning) }
    }

    func trust() {
        guard let cert else { return }
        trusted = cert.fingerprint
        UserDefaults.standard.set(cert.fingerprint, forKey: "trustedFingerprint")
    }

    func saveAddress() {
        UserDefaults.standard.set(manualAddress.trimmingCharacters(in: .whitespaces), forKey: "bambuddyAddress")
        Task { await refresh() }
    }

    func add(_ row: Row) {
        guard ready, let cert else { return }
        run(row) { installer, slicer in try installer.install(cert, into: slicer) }
    }

    func undo(_ row: Row) { run(row) { installer, slicer in try installer.undo(slicer) } }

    private func run(_ row: Row, _ action: @escaping @Sendable (Installer, Slicer) throws -> Void) {
        if row.slicer.isRunning {
            message = "\(CertError.slicerRunning(row.slicer.name))"
            return
        }
        busy = row.id
        message = nil
        let installer = installer, slicer = row.slicer
        Task {
            do {
                try await Task.detached { try action(installer, slicer) }.value
            } catch {
                message = "\(error)"
            }
            busy = nil
            await reloadSlicers()
        }
    }

    /// "printers.lan", "192.168.1.50:8000" or a full URL. A bare name gets Bambuddy's usual port.
    static func server(from text: String) -> Bambuddy? {
        guard var parts = URLComponents(string: text.contains("://") ? text : "http://\(text)"), parts.host?.isEmpty == false else { return nil }
        if parts.port == nil, !text.contains("://") { parts.port = Bambuddy.port }
        return parts.url.map { Bambuddy(address: $0) }
    }
}
