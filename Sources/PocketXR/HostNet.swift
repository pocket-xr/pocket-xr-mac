import Foundation
import Network
import Security
import PocketXRCore

/// One request as the host's HTTP, HTTPS and RTSP servers read it.
struct HostRequest {
    let method: String
    let target: String
    let headers: [String: String] // keys lower case
    let body: Data
    /// The address the request came in on (this Mac's, as the phone reached it) and the phone's.
    let local: String
    let remote: String
    /// The client certificate (DER) over HTTPS.
    let clientCert: Data?

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    var query: [String: String] {
        guard let i = target.firstIndex(of: "?") else { return [:] }
        var q: [String: String] = [:]
        for kv in target[target.index(after: i)...].split(separator: "&") {
            guard let e = kv.firstIndex(of: "=") else { continue }
            let k = String(kv[..<e]).removingPercentEncoding ?? String(kv[..<e])
            let v = String(kv[kv.index(after: e)...]).replacingOccurrences(of: "+", with: " ")
            q[k.lowercased()] = v.removingPercentEncoding ?? v
        }
        return q
    }
}

/// One request per connection, answered and closed (as the phone's GameStream calls and RTSP are made), over TCP,
/// with TLS that asks for a client certificate when an identity is given. IPv4 only. Ported in spirit from Pocket XR
/// for Windows' HostWeb and HostRtsp (GPLv3).
final class HostListener: @unchecked Sendable {
    let port: Int
    private var listener: NWListener?
    private let queue: DispatchQueue
    private let name: String
    /// The answer to a request: the whole response's bytes (status line, headers and body).
    private let handle: (HostRequest) -> Data

    init(name: String, port: Int, identity: SecIdentity?, loopbackOnly: Bool = false, handle: @escaping (HostRequest) -> Data) {
        self.name = name
        self.port = port
        self.handle = handle
        queue = DispatchQueue(label: "host-\(name)-\(port)", attributes: .concurrent)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params: NWParameters
        if let identity, let sid = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            let o = tls.securityProtocolOptions
            sec_protocol_options_set_local_identity(o, sid)
            sec_protocol_options_set_peer_authentication_required(o, true)
            sec_protocol_options_set_min_tls_protocol_version(o, .TLSv12)
            // Any client certificate is let in here; whether it is a paired phone's is checked per request.
            sec_protocol_options_set_verify_block(o, { _, _, complete in complete(true) }, queue)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        params.allowLocalEndpointReuse = true
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [name, port] s in
                if case .failed(let e) = s { plog("host: \(name) on \(port) failed: \(e)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            plog("host: \(name) on \(port): \(error)")
        }
    }

    var listening: Bool { listener != nil }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: self?.read(c, Data())
            case .failed, .cancelled: break
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 180) { c.cancel() } // nothing hangs on forever (pairing waits up to 2 min)
    }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var all = got
            if let data { all.append(data) }
            if let req = self.parse(all, c) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let answer = self.handle(req)
                    c.send(content: answer, completion: .contentProcessed { _ in c.cancel() })
                }
                return
            }
            if done || error != nil || all.count > 1 << 20 { c.cancel(); return }
            self.read(c, all)
        }
    }

    /// The request once its head and body are all in; nil while more is to come.
    private func parse(_ d: Data, _ c: NWConnection) -> HostRequest? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[d.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard d.count - (bodyStart - d.startIndex) >= length else { return nil }
        let body = d[bodyStart..<(bodyStart + length)]
        var cert: Data?
        if let meta = c.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            sec_protocol_metadata_access_peer_certificate_chain(meta.securityProtocolMetadata) { certificate in
                if cert == nil { cert = SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data }
            }
        }
        return HostRequest(method: first.first.map(String.init) ?? "", target: first.count > 1 ? String(first[1]) : "",
                           headers: headers, body: Data(body), local: Self.ip(c.currentPath?.localEndpoint),
                           remote: Self.ip(c.endpoint), clientCert: cert)
    }

    static func ip(_ e: NWEndpoint?) -> String {
        guard case .hostPort(let host, _)? = e else { return "" }
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return ""
        }
    }

    /// An HTTP/1.1 answer.
    static func http(_ status: Int, _ body: Data, type: String = "application/xml", extra: String = "") -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden"][status] ?? "Not Found"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A UDP socket bound to a port on all IPv4 addresses, with a thread that hears the client's pings (its address is
/// where the stream goes). Video and sound each have one.
final class HostUdp: @unchecked Sendable {
    let fd: Int32
    private(set) var client: sockaddr_in?
    private var stopping = false
    var firstClient: (() -> Void)?
    private let name: String

    /// Only pings from this address count (the device that launched the stream): another one still trying to reconnect
    /// (seen: the phone, while the Windows client streamed) would otherwise take the stream away.
    private let allowedIp: String?

    init?(port: Int, name: String, allowedIp: String? = nil) {
        self.name = name
        self.allowedIp = allowedIp?.isEmpty == true ? nil : allowedIp
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
        var size: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, 4)
        var tos: Int32 = 0xB8 // DSCP EF, as the client marks its own
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, 4)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(port).bigEndian
        a.sin_addr.s_addr = in_addr_t(0)
        let r = withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else {
            plog("host: \(name) port \(port): \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return nil
        }
        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let t = Thread { [weak self] in self?.pings() }
        t.name = "host-\(name)-pings"
        t.start()
    }

    var hasClient: Bool { client != nil }

    private func pings() {
        var buf = [UInt8](repeating: 0, count: 256)
        while !stopping {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n >= 4 {
                if let allowedIp, Self.text(from).split(separator: ":").first.map(String.init) != allowedIp { continue }
                let first = client == nil
                client = from
                if first {
                    plog("host: \(name) client at \(Self.text(from))")
                    firstClient?()
                }
            }
        }
    }

    func send(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        guard var to = client else { return false }
        let r = withUnsafePointer(to: &to) { tp in
            tp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == n
    }

    static func text(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return "\(String(cString: buf)):\(UInt16(bigEndian: a.sin_port))"
    }

    func close() {
        stopping = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
