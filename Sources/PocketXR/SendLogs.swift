import AppKit
import Foundation
import PocketXRCore

/// "Send logs to Mike": one zip of Pocket XR's logs in Downloads, with emails and IP addresses (other than the glasses'
/// own link-local ones) taken out, then an email to Mike with the zip shown in Finder to attach. Nothing is sent until
/// the user sends that email.
enum SendLogs {
    static let email = "connect@mikehaye.com"

    static func run() {
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()
        let work = fm.temporaryDirectory.appendingPathComponent("pocketxr-logs-\(stamp)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let folder = Log.shared.folder
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".log") {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
            try? clean(text).write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let about = """
        Pocket XR for Mac logs, sent with Send logs to Mike
        Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Mac: \(machine())
        Taken out of every line: email addresses and IP addresses other than the glasses' own link (169.254.x.x).
        """
        try? about.write(to: work.appendingPathComponent("about.txt"), atomically: true, encoding: .utf8)
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        let zip = downloads.appendingPathComponent("pocketxr-mac-logs-\(stamp).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", work.path, zip.path]
        try? p.run()
        p.waitUntilExit()
        try? fm.removeItem(at: work)
        plog("send logs: \(zip.lastPathComponent)")
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        let subject = "Pocket XR for Mac logs"
        let body = "Hi Mike,\n\nWhat happened (and roughly when):\n\n\n(Attach \(zip.lastPathComponent) from Downloads.)"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// Emails and IP addresses out, except the glasses' own link-local ones.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", with: "<email>", options: .regularExpression)
        let ip = try! NSRegularExpression(pattern: "\\b(\\d{1,3})\\.(\\d{1,3})\\.\\d{1,3}\\.\\d{1,3}\\b")
        let ns = t as NSString
        var out = ""
        var last = 0
        for m in ip.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
            out += (a == "169" && b == "254") || a == "127" ? ns.substring(with: m.range) : "<ip>"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        t = out
        return t
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
