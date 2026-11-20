import Foundation

// PC screens: a Windows PC's screens in the glasses, streamed from Apollo (or Sunshine) with Moonlight. The Mac app
// runs Moonlight itself, one copy per PC screen, full screen on a floating screen, so the capture that shows every
// floating screen shows it too. This file is the part that needs no Mac: addresses, which Apollo each PC screen uses,
// the PC helper's words and Moonlight's command lines. The rest is in the app's PcScreens.swift and Moonlight.swift.

/// One Apollo (or Sunshine) found on the network: a PC runs one per PC screen, each on its own port.
public struct PcHost: Equatable, Hashable, Sendable {
    /// The name it gives (mDNS gives every instance on a PC the PC's own name, numbered "Mike(2)" by order of start).
    public var name: String
    /// IPv4 address.
    public var address: String
    /// HTTP port: 47989 for the main Apollo, another for each extra one.
    public var port: Int

    public init(name: String, address: String, port: Int) {
        self.name = name
        self.address = address
        self.port = port
    }

    /// As Moonlight is given it: the port only when it is not the usual one.
    public var moonlightAddress: String { port == PcHostAddress.defaultPort ? address : "\(address):\(port)" }
}

public enum PcHostAddress {
    public static let defaultPort = 47989

    /// Host and port from `192.168.1.20`, `192.168.1.20:48989` or `pc.local:48989`; nil when empty or malformed.
    /// (IPv6 is not used: the Mac and the PC on one home network have IPv4.)
    public static func parse(_ text: String) -> (host: String, port: Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return (t, defaultPort) }
        guard parts.count == 2, !parts[0].isEmpty, let p = Int(parts[1]), (1...65535).contains(p) else { return nil }
        return (String(parts[0]), p)
    }
}

public enum PcScreenPick {
    /// The PC's name from an instance's name: "Mike(2)" and "MIKE screen 2" are both "Mike"'s.
    public static func pcName(_ serviceName: String) -> String {
        var s = serviceName.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"\(\d+\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"\s+screen\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? serviceName : s
    }

    /// The instances found, by PC (address), each PC named by its main instance, PCs in the order first found.
    public static func byPc(_ hosts: [PcHost]) -> [(name: String, address: String, instances: [PcHost])] {
        var order = [String]()
        var groups = [String: [PcHost]]()
        for h in hosts {
            if groups[h.address] == nil { order.append(h.address) }
            if groups[h.address]?.contains(where: { $0.port == h.port }) == true { continue }
            groups[h.address, default: []].append(h)
        }
        return order.map { address in
            let list = groups[address]!.sorted { $0.port < $1.port }
            let main = list.first { $0.port == PcHostAddress.defaultPort } ?? list[0]
            return (pcName(main.name), address, list)
        }
    }

    /// The instance a new PC screen uses: the main Apollo (the usual port) first, then the extra ones by port; only
    /// one no other PC screen uses ([used], as Moonlight addresses). Nil when every one is in use. Two PC screens on
    /// one Apollo show the same picture (Mike's phone, 19 Nov 2026), so that is never done.
    public static func next(of instances: [PcHost], used: Set<String>) -> PcHost? {
        let main = instances.filter { $0.port == PcHostAddress.defaultPort }
        let extra = instances.filter { $0.port != PcHostAddress.defaultPort }.sorted { $0.port < $1.port }
        return (main + extra).first { !used.contains($0.moonlightAddress) }
    }
}

/// The Pocket XR PC helper's protocol (port 47610; its source is pc-helper/PocketXrPcHelper.cs in the Android repo).
public enum PcHelperWire {
    public static let port: UInt16 = 47610
    public static let find = "POCKETXR-FIND 1"

    /// The helper's answer "POCKETXR-HERE 1 <tcp port> <PC name>": its TCP port and the PC's name; nil for anything else.
    public static func parseHere(_ text: String) -> (port: Int, name: String)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 3).map(String.init)
        guard parts.count >= 4, parts[0] == "POCKETXR-HERE", let p = Int(parts[2]), (1...65535).contains(p) else { return nil }
        return (p, parts[3])
    }

    /// One request line: a JSON object with keys in a fixed order (the helper does not mind; checks can compare).
    public static func request(_ fields: [(String, Any)]) -> String {
        var parts = [String]()
        for (k, v) in fields {
            let value: String
            // Bool before Int: a Bool can read as a number through Foundation.
            if let b = v as? Bool { value = b ? "true" : "false" } else if let n = v as? Int { value = String(n) } else { value = quoted("\(v)") }
            parts.append("\(quoted(k)):\(value)")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

/// Moonlight's command line (moonlight-qt 6.x: `Moonlight pair|list|stream <host> ...`).
public enum MoonlightCommand {
    /// A pairing PIN as Moonlight wants it: four digits.
    public static func pin<G: RandomNumberGenerator>(using g: inout G) -> String {
        String(format: "%04d", Int.random(in: 0...9999, using: &g))
    }

    public static func pair(_ host: PcHost, pin: String) -> [String] { ["pair", host.moonlightAddress, "--pin", pin] }

    public static func list(_ host: PcHost) -> [String] { ["list", host.moonlightAddress, "--csv"] }

    /// A PC screen's stream: the PC's desktop at the floating screen's size, full screen without a title bar, the
    /// pointer as on a remote desktop (it moves on and off the PC screen freely, not caught in it), and the Mac's
    /// own keys (Command-Tab) left to the Mac.
    public static func stream(_ host: PcHost, app: String, width: Int, height: Int, fps: Int) -> [String] {
        ["stream", host.moonlightAddress, app,
         "--resolution", "\(width)x\(height)", "--fps", "\(fps)",
         "--display-mode", "borderless",
         "--absolute-mouse",
         "--capture-system-keys", "never",
         "--no-game-optimization"]
    }

    /// The app a PC screen streams from what `list --csv` printed: Apollo's "Virtual Display" first (Apollo adds it
    /// when its virtual display driver is ready, and a session of it gets a screen of its own on the PC, of the
    /// size asked for; "Desktop" streams the PC's own monitor, the same picture on every PC screen), then "Desktop",
    /// then the first app listed. Nil when nothing is listed.
    public static func app(fromList output: String) -> String? { app(from: appNames(fromList: output)) }

    /// The same choice from app names already read.
    public static func app(from names: [String]) -> String? {
        for wanted in ["Virtual Display", "Desktop"] {
            if let n = names.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return n }
        }
        return names.first
    }

    /// App names from `list --csv`: the first field of each row, quotes taken off, without a header row.
    public static func appNames(fromList output: String) -> [String] {
        var names = [String]()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A CSV row has a comma; a message ("... has not been paired ...") might not.
            if line.isEmpty || !line.contains(",") { continue }
            var first: String
            if line.hasPrefix("\"") {
                let rest = line.dropFirst()
                guard let end = rest.firstIndex(of: "\"") else { continue }
                first = String(rest[..<end])
            } else {
                first = String(line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            }
            first = first.trimmingCharacters(in: .whitespaces)
            if first.isEmpty || first.caseInsensitiveCompare("Name") == .orderedSame { continue }
            names.append(first)
        }
        return names
    }
}
