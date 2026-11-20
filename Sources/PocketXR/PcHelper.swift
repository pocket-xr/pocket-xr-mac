import Foundation
import PocketXRCore

/// The Mac's side of the Pocket XR PC helper (a tray app on the Windows PC; PcHelperWire has its words): found by a
/// broadcast on the local network, allowed once on the PC (its user clicks Yes there), then it types Moonlight's
/// pairing PIN into Apollo for the user. Every call blocks: run them off the main thread.
final class PcHelper: @unchecked Sendable {
    struct Pc {
        let address: String
        let port: Int
        let name: String
    }

    private let defaults = UserDefaults.standard
    private static let lastAddressKey = "pcHelper.address"
    private static func tokenKey(_ pc: Pc) -> String { "pcHelper.token.\(pc.name)" }

    /// The Mac's name as its owner gave it ("Mike's MacBook Air"), as the PC's question and Apollo's client list show it.
    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// The helper's answer to a broadcast (or to the PC it was found at last time); nil when none answers.
    func find() -> Pc? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 700_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var targets = ["255.255.255.255"]
        if let last = defaults.string(forKey: Self.lastAddressKey) { targets.insert(last, at: 0) }
        let ask = Array(PcHelperWire.find.utf8)
        for _ in 0..<3 {
            for t in targets {
                var to = sockaddr_in()
                to.sin_family = sa_family_t(AF_INET)
                to.sin_port = PcHelperWire.port.bigEndian
                inet_pton(AF_INET, t, &to.sin_addr)
                _ = withUnsafePointer(to: &to) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, ask, ask.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            var buf = [UInt8](repeating: 0, count: 256)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0, let here = PcHelperWire.parseHere(String(decoding: buf[0..<n], as: UTF8.self)) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            let address = String(cString: text)
            defaults.set(address, forKey: Self.lastAddressKey)
            return Pc(address: address, port: here.port, name: here.name)
        }
        return nil
    }

    /// This Mac has been allowed on [pc] before.
    func knows(_ pc: Pc) -> Bool { defaults.string(forKey: Self.tokenKey(pc)) != nil }

    /// The PC's user is asked once whether this Mac may use the helper (a minute to answer). True when allowed.
    func pair(_ pc: Pc) -> Bool {
        guard let answer = ask(pc, [("op", "pair"), ("phone", Self.macName)], wait: 65),
              answer["ok"] as? Bool == true, let token = answer["token"] as? String, !token.isEmpty else { return false }
        defaults.set(token, forKey: Self.tokenKey(pc))
        return true
    }

    /// The helper types [pin] into the Apollo on HTTP port [port] for the user, and gives this Mac the permissions a
    /// PC screen needs, with Apollo's "always use virtual display" (Moonlight on macOS cannot ask for one, so without
    /// it every PC screen would show the PC's own monitor; the PC setup copies it to the extra Apollos). Nil when it
    /// worked, else why not.
    func apolloPin(_ pc: Pc, pin: String, port: Int) -> String? {
        guard let token = defaults.string(forKey: Self.tokenKey(pc)) else { return "not paired" }
        guard let answer = ask(pc, [("op", "apollo-pin"), ("token", token), ("pin", pin), ("name", Self.macName), ("port", port), ("virtual", true)], wait: 30) else {
            return "no answer"
        }
        if answer["why"] as? String == "not paired" { defaults.removeObject(forKey: Self.tokenKey(pc)) }
        return answer["ok"] as? Bool == true ? nil : (answer["why"] as? String ?? "refused")
    }

    /// Asks a helper that makes a virtual screen per stream (the Mac and Linux helpers: "virtual": true in their
    /// status) to ready the one behind HTTP port [port] at this size before Moonlight connects: their Sunshine checks
    /// its encoder on the screen before it runs its prep command. Nil when the screen is ready, else why not (the
    /// Windows helper, whose Apollo makes its own virtual display, refuses the request, and needs nothing).
    func prepareScreen(_ pc: Pc, port: Int, width: Int, height: Int, fps: Int) -> String? {
        guard let token = defaults.string(forKey: Self.tokenKey(pc)) else { return "not paired" }
        guard let answer = ask(pc, [("op", "screen-prepare"), ("token", token), ("port", port), ("width", width), ("height", height), ("fps", fps)], wait: 15) else {
            return "no answer"
        }
        return answer["ok"] as? Bool == true ? nil : (answer["why"] as? String ?? "refused")
    }

    /// One request, one answer line, within [wait] seconds.
    private func ask(_ pc: Pc, _ fields: [(String, Any)], wait: Int) -> [String: Any]? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = UInt16(pc.port).bigEndian
        inet_pton(AF_INET, pc.address, &to.sin_addr)
        var limit = timeval(tv_sec: wait, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var sendLimit = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendLimit, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &to) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            plog("PC helper on \(pc.name): could not connect (\(String(cString: strerror(errno))))")
            return nil
        }
        let line = Array((PcHelperWire.request(fields) + "\n").utf8)
        guard send(fd, line, line.count, 0) == line.count else { return nil }
        var got = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1024)
        while !got.contains(10) {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: got, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            plog("PC helper on \(pc.name): no answer")
            return nil
        }
        return object
    }
}
