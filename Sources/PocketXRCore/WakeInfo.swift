import Foundation

/// Waking a sleeping Mac from the phone (Wake-on-LAN): the phone sends a magic packet to the MAC address the host's
/// serverinfo gave it once paired (it takes 00:00:00:00:00:00 as none), and macOS wakes for it only with "Wake for
/// network access" on. The parts that need no Mac.
public enum WakeInfo {
    public static let none = "00:00:00:00:00:00"

    /// [bytes] as "a4:83:e7:12:34:56"; nil unless they are six bytes and not all zero.
    public static func macText(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public enum NetworkWake: Equatable, Sendable { case on, off, unknown }

    /// "Wake for network access" from `pmset -g custom`: the womp line under "AC Power:" (a laptop wakes for the network
    /// only on its power adapter); a Mac with one section (a desktop) has it there.
    public static func networkWake(pmsetCustom text: String) -> NetworkWake {
        var section = ""
        var found: [String: Int] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasSuffix("power:") {
                section = line.lowercased()
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "womp", let v = Int(parts[1]) { found[section] = v }
        }
        let value = found.first(where: { $0.key.hasPrefix("ac power") })?.value ?? (found.count == 1 ? found.first?.value : nil)
        guard let v = value else { return .unknown }
        return v != 0 ? .on : .off
    }

    /// The menu's line about waking this Mac from the phone.
    public static func hint(_ wake: NetworkWake) -> String {
        switch wake {
        case .on: return "Your phone can wake this Mac from sleep (Wake for network access is on)"
        case .off: return "To let your phone wake this Mac: System Settings > Battery > Options > Wake for network access"
        case .unknown: return "To let your phone wake this Mac: turn on Wake for network access (System Settings, Battery or Energy)"
        }
    }
}
