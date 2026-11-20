import AppKit
import ApplicationServices
import PocketXRCore

/// Moonlight (moonlight-qt, GPL-3.0, moonlight-stream.org): the app that shows a PC screen. Pocket XR runs its command
/// line: `pair` and `list` while setting up, and one `stream` per PC screen. Moonlight keeps one stream per process
/// and has no single-instance lock, so every PC screen is its own copy of it.
enum Moonlight {
    static let bundleID = "com.moonlight-stream.Moonlight"
    /// Used when GitHub's list of releases cannot be read.
    static let fallbackDmg = "https://github.com/moonlight-stream/moonlight-qt/releases/download/v6.2.0/Moonlight-6.2.0.dmg"
    static let downloadPage = "https://moonlight-stream.org"

    /// Moonlight.app where it is installed, or nil.
    static var app: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return u }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["/Applications/Moonlight.app", "\(home)/Applications/Moonlight.app"] where FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static var executable: URL? {
        guard let app else { return nil }
        return Bundle(url: app)?.executableURL ?? app.appendingPathComponent("Contents/MacOS/Moonlight")
    }

    // MARK: running it

    /// Runs Moonlight with [args] and waits up to [seconds]: its exit code (nil when it was stopped for taking too
    /// long) and what it printed. Blocking.
    static func run(_ args: [String], seconds: Double) -> (code: Int32?, out: String) {
        guard let exe = executable else { return (nil, "") }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var data = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        do { try p.run() } catch {
            plog("Moonlight \(args.first ?? ""): did not start: \(error.localizedDescription)")
            return (nil, "")
        }
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        var code: Int32? = nil
        if p.isRunning {
            p.terminate()
        } else {
            code = p.terminationStatus
        }
        _ = reading.wait(timeout: .now() + 2)
        return (code, String(decoding: data, as: UTF8.self))
    }

    /// Starts Moonlight with [args] and leaves it running; its output goes to Pocket XR's log as it comes.
    static func start(_ args: [String], label: String) -> Process? {
        guard let exe = executable else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            for line in String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline) where !line.isEmpty {
                plog("\(label): \(line.prefix(300))")
            }
        }
        do { try p.run() } catch {
            plog("\(label): Moonlight did not start: \(error.localizedDescription)")
            return nil
        }
        return p
    }

    /// The apps the host at [host] lists, from `list --csv`. Empty when Moonlight is not paired with it (or it does
    /// not answer). Blocking, up to 25 s.
    static func apps(_ host: PcHost) -> (names: [String], output: String) {
        let r = run(MoonlightCommand.list(host), seconds: 25)
        return (MoonlightCommand.appNames(fromList: r.out), r.out)
    }

    // MARK: its window

    /// The largest ordinary window of process [pid], in global display coordinates (top left origin), or nil.
    /// Window bounds need no permission.
    static func window(of pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: CGRect?
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width >= 320, rect.height >= 200 else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        return best
    }

    /// Moves process [pid]'s windows onto [bounds] (a display's, global coordinates): filling it when [fill], else
    /// in its middle at their own size. Needs Accessibility; false without it or when macOS refused.
    static func move(pid: pid_t, to bounds: CGRect, fill: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return false }
        var moved = false
        for w in windows {
            var size = bounds.size
            if !fill {
                var current: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &current) == .success, let v = current,
                   CFGetTypeID(v) == AXValueGetTypeID() {
                    AXValueGetValue(v as! AXValue, .cgSize, &size)
                }
            }
            var origin = fill ? bounds.origin
                : CGPoint(x: bounds.midX - min(size.width, bounds.width) / 2, y: bounds.midY - min(size.height, bounds.height) / 2)
            if let p = AXValueCreate(.cgPoint, &origin) {
                moved = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) == .success || moved
            }
            if fill, let s = AXValueCreate(.cgSize, &size) {
                _ = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
            }
        }
        return moved
    }

    // MARK: installing it

    enum InstallResult {
        case installed(URL)
        case failed(String)
    }

    /// Downloads Moonlight's latest macOS release from GitHub, checks that macOS accepts it (Developer ID signed and
    /// notarised, as Gatekeeper would check), and copies it to /Applications (or ~/Applications when that cannot be
    /// written). Blocking; [say] tells how far it is.
    static func install(say: @escaping (String) -> Void) -> InstallResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PocketXR-Moonlight-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        say("Downloading Moonlight…")
        let dmgURL = latestDmg() ?? URL(string: fallbackDmg)!
        plog("Moonlight: downloading \(dmgURL.absoluteString)")
        let dmg = work.appendingPathComponent("Moonlight.dmg")
        guard download(dmgURL, to: dmg) else { return .failed("The download did not finish.") }

        say("Installing Moonlight…")
        let mount = work.appendingPathComponent("mount")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = tool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard attach.code == 0 else {
            plog("Moonlight: hdiutil attach: \(attach.out)")
            return .failed("The download could not be opened.")
        }
        defer { _ = tool("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let entries = (try? fm.contentsOfDirectory(atPath: mount.path)) ?? []
        guard let name = entries.first(where: { $0.hasSuffix(".app") && $0.lowercased().contains("moonlight") }) else {
            return .failed("The download has no Moonlight in it.")
        }
        let source = mount.appendingPathComponent(name)
        // What Gatekeeper says of it, as if it had been opened from a browser's download.
        let assess = tool("/usr/sbin/spctl", ["--assess", "--type", "execute", "-v", source.path])
        plog("Moonlight: spctl: \(assess.out.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard assess.code == 0 else { return .failed("macOS did not accept this copy of Moonlight.") }

        for folder in ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: folder) else { continue }
            let target = URL(fileURLWithPath: folder).appendingPathComponent("Moonlight.app")
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            let copy = tool("/usr/bin/ditto", [source.path, target.path])
            if copy.code == 0 {
                plog("Moonlight: installed in \(target.path)")
                return .installed(target)
            }
            plog("Moonlight: copying to \(folder): \(copy.out)")
        }
        return .failed("Moonlight could not be copied into Applications.")
    }

    /// The .dmg of Moonlight's latest release, from GitHub's API; nil when it cannot be read.
    private static func latestDmg() -> URL? {
        guard let api = URL(string: "https://api.github.com/repos/moonlight-stream/moonlight-qt/releases/latest") else { return nil }
        var request = URLRequest(url: api)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let gate = DispatchSemaphore(value: 0)
        var found: URL?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { gate.signal() }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else { return }
            for a in assets {
                if let name = a["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                   let link = a["browser_download_url"] as? String, link.hasPrefix("https://github.com/") {
                    found = URL(string: link)
                    return
                }
            }
        }.resume()
        _ = gate.wait(timeout: .now() + 12)
        return found
    }

    private static func download(_ url: URL, to file: URL) -> Bool {
        let gate = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
            defer { gate.signal() }
            guard let temp, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                plog("Moonlight: download failed: \(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")")
                return
            }
            ok = (try? FileManager.default.moveItem(at: temp, to: file)) != nil
        }
        task.resume()
        if gate.wait(timeout: .now() + 600) == .timedOut {
            task.cancel()
            return false
        }
        return ok
    }

    private static func tool(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
