import AppKit
import IOKit.ps
import PocketXRCore
import SystemConfiguration

// What the launcher shows that comes from the Mac: its apps and their icons, the battery and whether Wi-Fi is
// connected. Nothing here asks macOS for a permission.

/// One app: the path to its bundle and its name as the Finder shows it.
struct LauncherApp: Identifiable, Equatable {
    let path: String
    let name: String
    var id: String { path }
}

enum LauncherApps {
    /// The folders looked through: every .app in them, and in the folders one level inside /Applications.
    static var folders: [String] {
        let home: String = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities", "\(home)/Applications"]
    }

    /// An app's name: the Finder's, without ".app".
    static func name(atPath path: String) -> String {
        let shown: String = FileManager.default.displayName(atPath: path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    /// Every app there is, by name. Reads folders, so it is called off the main thread.
    static func scan(leavingOut own: String) -> [LauncherApp] {
        let fm = FileManager.default
        var paths = [String]()
        var seen = Set<String>()

        func look(in folder: String, deeper: Bool) {
            guard let entries: [String] = try? fm.contentsOfDirectory(atPath: folder) else { return }
            for entry in entries where !entry.hasPrefix(".") {
                let path: String = "\(folder)/\(entry)"
                if entry.hasSuffix(".app") {
                    if seen.insert(path).inserted { paths.append(path) }
                } else if deeper {
                    var isFolder: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                        look(in: path, deeper: false)
                    }
                }
            }
        }

        for folder in folders { look(in: folder, deeper: folder == "/Applications") }
        let apps: [LauncherApp] = paths
            .filter { $0 != own }
            .map { LauncherApp(path: $0, name: name(atPath: $0)) }
            .filter { $0.name != "Pocket XR" && !$0.name.isEmpty }
        return apps.sorted {
            let order: ComparisonResult = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}

/// Apps' icons, kept once read.
@MainActor
final class LauncherIcons {
    private var kept = [String: NSImage]()

    func icon(forPath path: String) -> NSImage {
        if let have = kept[path] { return have }
        // Safari in /Applications is a link to where macOS really keeps it, and a link's icon gets the alias arrow:
        // the icon is read from what the link points at.
        let real: String = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let image: NSImage = NSWorkspace.shared.icon(forFile: real)
        image.size = NSSize(width: LauncherMetrics.icon, height: LauncherMetrics.icon)
        kept[path] = image
        return image
    }

    func forget(except paths: Set<String>) {
        kept = kept.filter { paths.contains($0.key) }
    }
}

/// The battery as the launcher shows it.
struct LauncherBattery: Equatable {
    /// 0 to 100.
    let percent: Int
    /// Plugged in (charging or full).
    let onMains: Bool

    /// The Mac's battery from IOKit's power sources; nil on a Mac with none.
    static func read() -> LauncherBattery? {
        guard let info: CFTypeRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list: [CFTypeRef] = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            if let present = d[kIOPSIsPresentKey] as? Bool, !present { continue }
            guard let now = d[kIOPSCurrentCapacityKey] as? Int, let full = d[kIOPSMaxCapacityKey] as? Int, full > 0 else { continue }
            let percent: Int = min(max(Int((Double(now) / Double(full) * 100).rounded()), 0), 100)
            let mains: Bool = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return LauncherBattery(percent: percent, onMains: mains)
        }
        return nil
    }
}

/// Wi-Fi as far as it can be known without asking for anything: the network's name needs Location on macOS 14, so
/// only whether the Wi-Fi interface has an address is read.
enum LauncherWifi: Equatable {
    case connected, off

    /// Nil on a Mac with no Wi-Fi.
    static func read() -> LauncherWifi? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        var names = Set<String>()
        for i in all {
            guard let type = SCNetworkInterfaceGetInterfaceType(i), (type as String) == (kSCNetworkInterfaceTypeIEEE80211 as String) else { continue }
            if let bsd = SCNetworkInterfaceGetBSDName(i) { names.insert(bsd as String) }
        }
        if names.isEmpty { return nil }

        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return .off }
        defer { freeifaddrs(start) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let c = cursor {
            let a: ifaddrs = c.pointee
            cursor = a.ifa_next
            guard let addr = a.ifa_addr, names.contains(String(cString: a.ifa_name)) else { continue }
            let up: Bool = (Int32(a.ifa_flags) & IFF_UP) != 0 && (Int32(a.ifa_flags) & IFF_RUNNING) != 0
            if up && Int32(addr.pointee.sa_family) == AF_INET { return .connected }
        }
        return .off
    }
}
