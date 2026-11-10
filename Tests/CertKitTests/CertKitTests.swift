import Darwin
import Foundation
import Testing
@testable import CertKit

// MARK: Certificates

@Test func readsEveryCertificateInAFileAndMatchesOpenSSLsFingerprint() throws {
    let (a, ca) = try makeCA("One"), (b, _) = try makeCA("Two")
    #expect(PEM.certificates(in: a + "\n" + b).count == 2)
    #expect(ca.commonName == "One")
    let dir = tempDir(), file = dir.appending(path: "c.pem")
    try Data(a.utf8).write(to: file)
    let openssl = try run("/usr/bin/openssl", ["x509", "-in", file.path, "-noout", "-fingerprint", "-sha256"])
    #expect(openssl.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) == ca.fingerprint)
    #expect(PEM.certificates(in: ca.pem) == [ca.der], "our PEM reads back the same")
}

@Test func garbageIsNotACertificate() {
    #expect(throws: CertError.notACertificate) { try CACertificate(der: Data("hello".utf8)) }
    #expect(PEM.certificates(in: "no certificates here").isEmpty)
}

// MARK: Bambuddy

@Test func fetchesAndChecksBambuddysCertificate() async throws {
    let (pem, ca) = try makeCA()
    let server = try await FakeServer(body: bambuddyReply(pem: pem, fingerprint: ca.fingerprint.lowercased().replacingOccurrences(of: ":", with: "")))
    defer { server.stop() }
    let got = try await Bambuddy(address: server.address, apiKey: "bb_test").certificate()
    #expect(got == ca)
    #expect(server.headers.first?.contains("GET /api/v1/virtual-printers/ca-certificate") == true)
    #expect(server.headers.first?.lowercased().contains("x-api-key: bb_test") == true)
}

@Test func refusesAReplyThatDoesntAddUp() async throws {
    let (pem, ca) = try makeCA(), (other, _) = try makeCA("Other")
    let cases: [(String, Int, CertError)] = [
        (bambuddyReply(pem: pem, fingerprint: String(repeating: "AB", count: 32)), 200, .fingerprintMismatch),
        (bambuddyReply(pem: pem + other, fingerprint: ca.fingerprint), 200, .notACertificate),
        ("<html>openmediavault</html>", 200, .notBambuddy("127.0.0.1")),
        (#"{"detail":"Not authenticated"}"#, 401, .notBambuddy("127.0.0.1")),
    ]
    for (body, status, expected) in cases {
        let server = try await FakeServer(status: status, body: body)
        defer { server.stop() }
        await #expect(throws: expected) { try await Bambuddy(address: server.address).certificate() }
    }
}

@Test func refusesAnExpiredCertificate() async throws {
    let (pem, ca) = try makeCA(days: 30)
    let server = try await FakeServer(body: bambuddyReply(pem: pem, fingerprint: ca.fingerprint))
    defer { server.stop() }
    await #expect(throws: CertError.expired) { try await Bambuddy(address: server.address).certificate(now: Date().addingTimeInterval(31 * 86_400)) }
}

@Test func findsTheVirtualPrinterBySearching() async {
    let fake = fakeSSDP(location: "192.168.1.50")
    defer { fake.stop() }
    let found = await Discovery.search(to: "127.0.0.1", port: fake.port, wait: 1)
    #expect(found == ["192.168.1.50"])
}

@Test func readsBambuddyTraysAddressAndKey() throws {
    let file = tempDir().appending(path: "config.json")
    try Data(#"{"base_url": "http://bambuddy.lan:8000", "api_key": "bb_x", "poll_seconds": 20}"#.utf8).write(to: file)
    #expect(Tray.read(file) == Bambuddy(address: URL(string: "http://bambuddy.lan:8000")!, apiKey: "bb_x"))
    try Data(#"{"base_url": "file:///etc/passwd"}"#.utf8).write(to: file)
    #expect(Tray.read(file) == nil)
}

// MARK: Installing

@Test func addsReSignsAndUndoesExactly() throws {
    let (existing, _) = try makeCA("Bambu Lab CA"), (_, ca) = try makeCA(), (_, second) = try makeCA("Second")
    let slicer = try makeSlicer(certs: existing)
    let program = slicer.app.appending(path: "Contents/MacOS/fake"), seal = slicer.app.appending(path: "Contents/_CodeSignature/CodeResources")
    let originalProgram = try Data(contentsOf: program), originalSeal = try Data(contentsOf: seal)
    let installer = Installer(backups: tempDir())
    #expect(installer.state(of: slicer, for: ca) == .init(trusted: false, signatureValid: true, canUndo: false))

    setxattr(slicer.app.path, "com.apple.quarantine", "0381;6af27b33;Safari;", 21, 0, 0)
    #expect(try installer.install(ca, into: slicer))
    #expect(getxattr(slicer.app.path, "com.apple.quarantine", nil, 0, 0, 0) < 0, "a downloaded slicer's flag goes, or Gatekeeper refuses it")
    let after = try String(contentsOf: slicer.certFile, encoding: .utf8)
    #expect(after.hasPrefix(existing), "the slicer's own certificates stay first and unchanged")
    #expect(PEM.certificates(in: after).count == 2)
    #expect(try Data(contentsOf: program) != originalProgram, "re-signing rewrote the signature")
    #expect(installer.state(of: slicer, for: ca) == .init(trusted: true, signatureValid: true, canUndo: true))

    #expect(try installer.install(ca, into: slicer) == false, "a second add changes nothing")
    #expect(try String(contentsOf: slicer.certFile, encoding: .utf8) == after)
    #expect(try installer.install(second, into: slicer), "a new certificate after an update in Bambuddy")

    try installer.undo(slicer)
    #expect(try String(contentsOf: slicer.certFile, encoding: .utf8) == existing, "undo goes back to before the first change")
    #expect(try Data(contentsOf: program) == originalProgram, "with the original signature")
    #expect(try Data(contentsOf: seal) == originalSeal)
    #expect(installer.state(of: slicer, for: ca) == .init(trusted: false, signatureValid: true, canUndo: false))
    #expect(throws: CertError.nothingToUndo) { try installer.undo(slicer) }
}

@Test func anUpdatedSlicerGetsAFreshSnapshot() throws {
    let (existing, _) = try makeCA("Bambu Lab CA"), (_, ca) = try makeCA()
    let slicer = try makeSlicer(certs: existing)
    let installer = Installer(backups: tempDir())
    #expect(try installer.install(ca, into: slicer))
    // An update brings a new version and the original file back.
    let plist = slicer.app.appending(path: "Contents/Info.plist")
    let info = NSMutableDictionary(contentsOf: plist)!
    info["CFBundleShortVersionString"] = "2.0"
    info.write(to: plist, atomically: true)
    try Data(existing.utf8).write(to: slicer.certFile)
    try run("/usr/bin/codesign", ["--force", "--sign", "-", slicer.app.path])
    #expect(installer.state(of: slicer, for: ca).canUndo == false, "the old snapshot belongs to the old version")
    #expect(try installer.install(ca, into: slicer))
    try installer.undo(slicer)
    #expect(try String(contentsOf: slicer.certFile, encoding: .utf8) == existing)
}

@Test func aBrokenSignatureShowsUp() throws {
    let (existing, _) = try makeCA("Bambu Lab CA"), (_, ca) = try makeCA()
    let slicer = try makeSlicer(certs: existing)
    try Data((existing + ca.pem).utf8).write(to: slicer.certFile)   // the wiki's manual way, without re-signing
    #expect(Installer(backups: tempDir()).state(of: slicer, for: ca) == .init(trusted: true, signatureValid: false, canUndo: false))
}

@Test func aFileItCantWriteIsReportedAndLeftAlone() throws {
    let (existing, _) = try makeCA("Bambu Lab CA"), (_, ca) = try makeCA()
    let slicer = try makeSlicer(certs: existing)
    let dir = slicer.certFile.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    #expect(throws: CertError.noPermission("Fake Slicer")) { try Installer(backups: tempDir()).install(ca, into: slicer) }
    #expect(try String(contentsOf: slicer.certFile, encoding: .utf8) == existing)
}

// MARK: Live, opt-in: `LIVE=1 swift test --filter live`. Reads only.

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE"] == "1"))
@MainActor
func liveFindsBambuddyAndReadsTheSlicers() async throws {
    let found = try #require(await Bambuddy.find(), "no Bambuddy on this network")
    print("Bambuddy at \(found.0.address.absoluteString): \(found.1.fingerprint)")
    for slicer in Slicer.installed() {
        print(slicer.name, slicer.app.path, Installer().state(of: slicer, for: found.1))
    }
}

/// `LIVE_APP=<slicer>.app LIVE_STEP=add|undo LIVE_BACKUPS=<dir> swift test --filter liveApp`: the real change,
/// one step at a time, on an app you can reinstall.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_APP"] != nil))
func liveAppStep() async throws {
    let env = ProcessInfo.processInfo.environment
    let slicer = Slicer(name: "Live", bundleID: "live", app: URL(filePath: env["LIVE_APP"]!))
    let installer = Installer(backups: URL(filePath: env["LIVE_BACKUPS"]!))
    let (_, cert) = try #require(await Bambuddy.find())
    if env["LIVE_STEP"] == "undo" {
        try installer.undo(slicer)
        #expect(installer.state(of: slicer, for: cert) == .init(trusted: false, signatureValid: true, canUndo: false))
    } else {
        #expect(try installer.install(cert, into: slicer))
        #expect(installer.state(of: slicer, for: cert) == .init(trusted: true, signatureValid: true, canUndo: true))
    }
}
