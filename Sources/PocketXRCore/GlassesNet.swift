import Darwin
import Foundation

/// The glasses' USB network on the Mac.
///
/// The Aura and the One family show up as a USB Ethernet device (CDC NCM; macOS's ECM driver reportedly skips ECM in
/// a composite device) with the glasses at 169.254.2.1 and the Mac on another 169.254.2.x address. Several interfaces
/// can be on 169.254/16 at once (the glasses' two links, Wi-Fi's self-assigned address), and Apple's QA1357 says
/// link-local is only active on the primary interface, so the routing table is not trusted: the interface that holds a
/// 169.254.2.x (or 169.254.1.x) address is found with getifaddrs, and sockets are bound to it with IP_BOUND_IF.
public enum GlassesNet {
    /// One candidate: the interface's name ("en7"), its index, the Mac's own address on it, and the glasses' address.
    public struct Route: Equatable, Sendable, CustomStringConvertible {
        public var interface: String
        public var index: UInt32
        public var local: String
        public var glasses: String

        public var description: String { "\(interface) (\(local) -> \(glasses))" }
    }

    /// The glasses' link for each interface with a 169.254.2.x address (NCM first), then 169.254.1.x (ECM).
    public static func routes() -> [Route] {
        var out = [Route]()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(truncatingIfNeeded: ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let ip = UInt32(bigEndian: addr.s_addr)
            guard ip >> 16 == 0xA9FE else { continue } // 169.254/16
            let third = (ip >> 8) & 0xFF
            guard third == 2 || third == 1 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let local = "169.254.\(third).\(ip & 0xFF)"
            out.append(Route(interface: name, index: if_nametoindex(name), local: local, glasses: "169.254.\(third).1"))
        }
        return out.sorted { a, b in a.glasses == "169.254.2.1" && b.glasses != "169.254.2.1" }
    }

    /// Every IPv4 interface with its address, for the log when the glasses' link is not found.
    public static func describeInterfaces() -> String {
        var parts = [String]()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "getifaddrs failed" }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = addr
            inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            parts.append("\(String(cString: ifa.pointee.ifa_name)) \(String(cString: buf))")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    public enum NetError: Error, CustomStringConvertible {
        case socket(Int32), connect(String, Int32), timeout(String), closed

        public var description: String {
            switch self {
            case .socket(let e): return "socket: \(String(cString: strerror(e)))"
            case .connect(let to, let e): return "connect to \(to): \(String(cString: strerror(e)))"
            case .timeout(let to): return "connect to \(to): timed out"
            case .closed: return "closed by the glasses"
            }
        }
    }

    /// A connected TCP socket to [host]:[port], bound to [route]'s interface when given. Blocking reads, with a
    /// receive timeout of [readTimeoutS] so a reader can notice it was asked to stop.
    public static func connect(host: String, port: UInt16, route: Route?, timeoutS: Double = 3, readTimeoutS: Double = 0.5) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw NetError.socket(errno) }
        var ok = false
        defer { if !ok { close(fd) } }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if let r = route, r.index != 0 {
            var idx = r.index
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        // Non-blocking connect, so an absent link fails in [timeoutS] rather than the system's 75 s.
        let fl = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let to = "\(host):\(port)" + (route.map { " on \($0.interface)" } ?? "")
        if rc != 0 {
            guard errno == EINPROGRESS else { throw NetError.connect(to, errno) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&pfd, 1, Int32(timeoutS * 1000))
            guard n > 0 else { throw NetError.timeout(to) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { throw NetError.connect(to, err) }
        }
        _ = fcntl(fd, F_SETFL, fl)
        var tv = timeval(tv_sec: Int(readTimeoutS), tv_usec: Int32((readTimeoutS - Double(Int(readTimeoutS))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        ok = true
        return fd
    }

    /// Opens [port] on the glasses on the first route that answers: each found interface, then a plain connect to
    /// 169.254.2.1 and 169.254.1.1. Returns the socket and how it was reached.
    public static func open(port: UInt16, log: (String) -> Void) throws -> (Int32, String) {
        var tries: [(String, Route?)] = routes().map { ($0.glasses, $0) }
        tries.append(("169.254.2.1", nil))
        tries.append(("169.254.1.1", nil))
        var last: Error = NetError.closed
        for (host, route) in tries {
            do {
                let fd = try connect(host: host, port: port, route: route)
                return (fd, route.map { $0.description } ?? "\(host), unbound")
            } catch {
                last = error
            }
        }
        log("glasses link: port \(port) not reachable (\(last)); interfaces: \(describeInterfaces())")
        throw last
    }

    /// Writes all of [bytes]; throws when the link is gone.
    public static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                throw NetError.closed
            }
            sent += n
        }
    }

    /// Reads what has come, up to 64 KB: an empty array after the read timeout, nil when the link closed.
    public static func receive(_ fd: Int32, _ buf: inout [UInt8]) -> [UInt8]? {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
        if n > 0 { return Array(buf[0..<n]) }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return [] }
        return nil
    }
}
