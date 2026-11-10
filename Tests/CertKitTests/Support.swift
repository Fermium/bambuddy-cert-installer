import Darwin
import Foundation
import Network
@testable import CertKit

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "certkit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) throws -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(filePath: tool)
    p.arguments = arguments
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: tool, code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text]) }
    return text
}

/// A fresh self-signed CA, made the way Bambuddy makes its own.
func makeCA(_ name: String = "Virtual Printer CA", days: Int = 7300) throws -> (pem: String, cert: CACertificate) {
    let dir = tempDir()
    try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir.appending(path: "k.pem").path,
                                 "-out", dir.appending(path: "c.pem").path, "-days", "\(days)", "-subj", "/CN=\(name)"])
    let pem = try String(contentsOf: dir.appending(path: "c.pem"), encoding: .utf8)
    return (pem, try CACertificate(der: PEM.certificates(in: pem)[0]))
}

/// A tiny signed app with a printer.cer, standing in for a slicer.
func makeSlicer(certs: String) throws -> Slicer {
    let app = tempDir().appending(path: "Fake Slicer.app", directoryHint: .isDirectory)
    let contents = app.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: contents.appending(path: "Resources/cert"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: contents.appending(path: "MacOS/fake"))
    let plist: [String: Any] = ["CFBundleIdentifier": "test.fake-slicer.\(UUID().uuidString)", "CFBundleExecutable": "fake", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    try Data(certs.utf8).write(to: contents.appending(path: "Resources/cert/printer.cer"))
    try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    return Slicer(name: "Fake Slicer", bundleID: plist["CFBundleIdentifier"] as! String, app: app)
}

/// Answers one path with a fixed body on loopback, like a Bambuddy would.
final class FakeServer: @unchecked Sendable {
    /// What arrived, request by request.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    private let listener: NWListener
    private let log = Log()
    let port: UInt16
    var headers: [String] { log.all }

    init(status: Int = 200, body: String) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let reply = Data("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        let log = log
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data { log.add(String(decoding: data, as: UTF8.self)) }
                c.send(content: reply, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        port = await withCheckedContinuation { (done: CheckedContinuation<UInt16, Never>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { done.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: .global())
        }
        self.listener = listener
    }

    var address: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func stop() { listener.cancel() }
}

/// Answers printer searches on loopback, the way Bambuddy's virtual printer does.
func fakeSSDP(location: String) -> (port: UInt16, stop: @Sendable () -> Void) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    let reply = "HTTP/1.1 200 OK\r\nServer: UPnP/1.0\r\nLocation: \(location)\r\nST: \(Discovery.searchTarget)\r\nDevName.bambu.com: My Printer\r\n\r\n"
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        while true {
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &size) } }
            if n <= 0 { return }
            guard String(decoding: buffer[..<n], as: UTF8.self).hasPrefix("M-SEARCH") else { continue }
            _ = reply.withCString { text in
                withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, text, strlen(text), 0, $0, size) } }
            }
        }
    }
    return (UInt16(bigEndian: address.sin_port), { shutdown(fd, SHUT_RDWR); close(fd) })
}

func bambuddyReply(pem: String, fingerprint: String) -> String {
    let body: [String: Any] = ["pem": pem, "fingerprint_sha256": fingerprint, "not_valid_after": "2046-07-07T22:26:11+00:00"]
    return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
}
