import Darwin
import Foundation

/// A Bambuddy server, and how to find one on the local network.
public struct Bambuddy: Sendable, Equatable {
    public static let port = 8000
    public var address: URL
    /// Only needed when Bambuddy's login is on. It needs the "read status" permission.
    public var apiKey: String?

    public init(address: URL, apiKey: String? = nil) {
        self.address = address
        self.apiKey = apiKey
    }

    private struct Reply: Decodable {
        var pem: String
        var fingerprint_sha256: String
    }

    /// The virtual printer CA, checked: exactly one certificate, matching the fingerprint Bambuddy sends, not expired.
    public func certificate(session: URLSession = .shared, now: Date = Date()) async throws -> CACertificate {
        var request = URLRequest(url: address.appending(path: "api/v1/virtual-printers/ca-certificate"), timeoutInterval: 5)
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        let shown = address.host() ?? address.absoluteString
        guard let (data, reply) = try? await session.data(for: request), (reply as? HTTPURLResponse)?.statusCode == 200,
              data.count < 64_000, let json = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw CertError.notBambuddy(shown)
        }
        let found = PEM.certificates(in: json.pem)
        guard found.count == 1 else { throw CertError.notACertificate }
        let cert = try CACertificate(der: found[0])
        guard CACertificate.normalize(json.fingerprint_sha256) == CACertificate.normalize(cert.fingerprint) else { throw CertError.fingerprintMismatch }
        if let expires = cert.expires, expires < now { throw CertError.expired }
        return cert
    }

    /// Where to look, best first: whatever answers a printer search (Bambuddy's virtual printer answers like
    /// a printer), Bambuddy Tray's address, then the usual names.
    public static func candidates(trayConfig: URL = Tray.config) async -> [Bambuddy] {
        var found = await Discovery.search().compactMap { ip in URL(string: "http://\(ip):\(port)").map { Bambuddy(address: $0) } }
        if let tray = Tray.read(trayConfig) { found.append(tray) }
        for name in ["bambuddy.lan", "bambuddy.local"] {
            if let url = URL(string: "http://\(name):\(port)") { found.append(Bambuddy(address: url)) }
        }
        // One entry per address. The Tray's key stays with the Tray's address, and no other.
        var unique: [Bambuddy] = []
        for candidate in found {
            if let i = unique.firstIndex(where: { $0.address == candidate.address }) {
                unique[i].apiKey = unique[i].apiKey ?? candidate.apiKey
            } else {
                unique.append(candidate)
            }
        }
        return unique
    }

    /// The first candidate that serves a valid certificate.
    public static func find(trayConfig: URL = Tray.config) async -> (Bambuddy, CACertificate)? {
        for candidate in await candidates(trayConfig: trayConfig) {
            if let cert = try? await candidate.certificate() { return (candidate, cert) }
        }
        return nil
    }
}

/// Bambuddy Tray's saved settings, if it's installed.
public enum Tray {
    public static let config = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/BambuddyTray/config.json")

    private struct Config: Decodable {
        var base_url: String
        var api_key: String?
    }

    static func read(_ file: URL) -> Bambuddy? {
        guard let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(Config.self, from: data),
              let url = URL(string: config.base_url), url.scheme == "http" || url.scheme == "https" else { return nil }
        return Bambuddy(address: url, apiKey: config.api_key)
    }
}

/// The search Bambu slicers send. Bambuddy's virtual printer answers it, and broadcasts only every 30 seconds.
public enum Discovery {
    public static let searchTarget = "urn:bambulab-com:device:3dprinter:1"

    /// The addresses that answered, in order.
    public static func search(to host: String = "255.255.255.255", port: UInt16 = 2021, wait: TimeInterval = 1.5) async -> [String] {
        await Task.detached { searchNow(host: host, port: port, wait: wait) }.value
    }

    private static func searchNow(host: String, port: UInt16, wait: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &target.sin_addr)
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(searchTarget)\r\n\r\n"
        let sent = message.withCString { text in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, text, strlen(text), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard sent > 0 else { return [] }
        var found: [String] = []
        let deadline = Date().addingTimeInterval(wait)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(max(deadline.timeIntervalSinceNow, 0) * 1000)) > 0 else { break }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0, let ip = answer(String(decoding: buffer[..<count], as: UTF8.self), from: from), !found.contains(ip) else { continue }
            found.append(ip)
        }
        return found
    }

    /// The address a search answer points to: its Location, or else who sent it.
    static func answer(_ text: String, from sender: sockaddr_in) -> String? {
        guard text.contains(searchTarget), !text.hasPrefix("M-SEARCH") else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                let location = parts[1].trimmingCharacters(in: .whitespaces)
                if !location.isEmpty, !location.contains("/") { return location }
            }
        }
        var address = sender.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) }
    }
}
