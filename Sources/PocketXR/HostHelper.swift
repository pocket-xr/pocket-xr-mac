import AppKit
import Network
import ScreenCaptureKit
import PocketXRCore

/// The Pocket XR PC helper's words (UDP and TCP 47610), answered by Pocket XR for Mac itself, so the phone pairs with
/// nothing typed and knows this is a Mac with a virtual screen per PC screen ("os":"mac", "virtual": true). As the PC
/// helper for Mac speaks them (pocket-xr-pcscreen/pc-helper/mac, Wire.swift), with the PIN going straight to this
/// app's host instead of into a Sunshine:
///
///   UDP  "POCKETXR-FIND 1"  ->  "POCKETXR-HERE 1 47610 <computer name>"
///   TCP  one JSON line in, one out:
///     {"op":"pair","phone"}                         this Mac's user is asked; {"ok":true,"token","pc"} or why not
///     {"op":"apollo-pin","token","pin","name","port"}  the PIN for the host on [port]; {"ok":true} or why not
///     {"op":"screen-prepare","token","port","width","height","fps"}  that host's virtual screen ready; {"ok":true,"screen":N}
///     {"op":"screens-setup","token","phone"}        the permission settings open on this Mac; {"ok":true}
///     {"op":"status"|"start","token"}               {"ok":true,"pc","steam":false,...,"os":"mac","virtual":true}
///
/// This replaces the separate Pocket XR PC helper app for Mac (same words, so phones already released keep working).
/// If that app still runs, it has the port: this one tries again every 10 s and takes the port once it is free.
/// The phones that app allowed are taken over the first time (its phones.json), so they are not asked again.
final class HostHelper: @unchecked Sendable {
    /// 47610 (PXR_HOST_HELPER_PORT: another, for tests beside a running PC helper app).
    static let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["PXR_HOST_HELPER_PORT"] ?? "") ?? 47610
    private let shared: HostShared
    private var tcp: NWListener?
    private var udpFd: Int32 = -1
    private var stopping = false
    private let queue = DispatchQueue(label: "host-helper", attributes: .concurrent)
    private let phonesLock = NSLock()
    private var retry: DispatchSourceTimer?
    /// Both ports are this app's (not the old PC helper app's).
    var running: Bool { tcp != nil && udpFd >= 0 }
    static var phonesFile: URL { HostIdentity.folder.appendingPathComponent("phones.json") }
    /// The separate PC helper app's list (same format), taken over once.
    static var oldPhonesFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pocket XR PC helper/phones.json")
    }

    init(shared: HostShared) { self.shared = shared }

    var computerName: String { Host.current().localizedName ?? "Mac" }

    func start() {
        takeOverOldPhones()
        bindAll(firstTry: true)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopping, !self.running else { return }
            self.bindAll(firstTry: false)
        }
        t.resume()
        retry = t
    }

    private var warned = false

    private func bindAll(firstTry: Bool) {
        if tcp == nil { startTcp() }
        if udpFd < 0 { startUdp() }
        if running && !firstTry { plog("host: PC helper words on \(Self.port) now answered here") }
        if !running && !warned {
            warned = true
            plog("host: port \(Self.port) is in use (the old Pocket XR PC helper app running?): trying again every 10 s")
        }
    }

    private func startTcp() {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed = s {
                    l.cancel()
                    self?.queue.async(flags: .barrier) { if self?.tcp === l { self?.tcp = nil } }
                }
            }
            l.start(queue: queue)
            tcp = l
        } catch {
            tcp = nil
        }
    }

    func stop() {
        stopping = true
        retry?.cancel()
        tcp?.cancel()
        tcp = nil
        if udpFd >= 0 { shutdown(udpFd, SHUT_RDWR); close(udpFd); udpFd = -1 }
    }

    private func startUdp() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = Self.port.bigEndian
        a.sin_addr.s_addr = in_addr_t(0)
        let r = withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else {
            close(fd)
            return
        }
        udpFd = fd
        let t = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            while let self, !self.stopping {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
                guard n > 0 else { if n < 0 { return }; continue }
                guard Array(buf[0..<n]).starts(with: Array("POCKETXR-FIND".utf8)) else { continue }
                let here = Array("POCKETXR-HERE 1 \(Self.port) \(self.computerName.replacingOccurrences(of: "\n", with: " "))".utf8)
                _ = withUnsafePointer(to: &from) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, here, here.count, 0, $0, len) } }
            }
        }
        t.name = "host-helper-find"
        t.start()
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
        queue.asyncAfter(deadline: .now() + 90) { c.cancel() }
    }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            var all = got
            if let data { all.append(data) }
            if let nl = all.firstIndex(of: 10) {
                let line = String(decoding: all[all.startIndex..<nl], as: UTF8.self)
                let remote = HostListener.ip(c.endpoint)
                DispatchQueue.global(qos: .userInitiated).async {
                    let answer = self.answer(line, from: remote)
                    c.send(content: Data((answer + "\n").utf8), completion: .contentProcessed { _ in c.cancel() })
                }
                return
            }
            if done || error != nil || all.count > 65536 { c.cancel(); return }
            self.read(c, all)
        }
    }

    private func encode(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return #"{"ok":false}"# }
        return String(decoding: d, as: UTF8.self)
    }

    private static func text(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func number(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// Allowed phones, token to name, in the PC helper's own file format ({"phones":[{"name","token"}]}, 0600).
    private var phones: [String: String] {
        get {
            phonesLock.lock(); defer { phonesLock.unlock() }
            return Self.readPhones(Self.phonesFile)
        }
        set {
            phonesLock.lock(); defer { phonesLock.unlock() }
            Self.writePhones(newValue)
        }
    }

    static func readPhones(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = o["phones"] as? [[String: Any]] else { return [:] }
        var m: [String: String] = [:]
        for p in list { if let t = p["token"] as? String, !t.isEmpty { m[t] = p["name"] as? String ?? "A phone" } }
        return m
    }

    private static func writePhones(_ m: [String: String]) {
        try? FileManager.default.createDirectory(at: HostIdentity.folder, withIntermediateDirectories: true)
        let list = m.sorted { $0.key < $1.key }.map { ["name": $0.value, "token": $0.key] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["phones": list], options: [.sortedKeys]) else { return }
        FileManager.default.createFile(atPath: phonesFile.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// The old PC helper app's allowed phones, taken over while this list is still empty: those phones keep their
    /// token and are not asked again.
    private func takeOverOldPhones() {
        guard phones.isEmpty else { return }
        let old = Self.readPhones(Self.oldPhonesFile)
        guard !old.isEmpty else { return }
        phones = old
        plog("host: took over \(old.count) phone(s) the Pocket XR PC helper app had allowed")
    }

    /// Forgets every phone allowed here (they are asked again).
    func forgetPhones() { phones = [:] }

    private func answer(_ line: String, from address: String) -> String {
        guard let data = line.data(using: .utf8), let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return encode(["ok": false, "why": "not a request"])
        }
        let op = req["op"] as? String ?? ""
        if op == "pair" {
            let phone = Self.text(req["phone"]) ?? "A phone"
            plog("host: \(phone) at \(address) asks to use this Mac")
            guard allow(phone: phone) else { return encode(["ok": false, "why": "not allowed on the PC"]) }
            var p = phones
            let token = UUID().uuidString
            p[token] = phone
            phones = p
            return encode(["ok": true, "token": token, "pc": computerName])
        }
        guard let token = req["token"] as? String, phones[token] != nil else { return encode(["ok": false, "why": "not paired"]) }
        switch op {
        case "apollo-pin":
            guard let pin = Self.text(req["pin"]) else { return encode(["ok": false, "why": "no PIN"]) }
            let port = Self.number(req["port"]) ?? HostServer.basePorts[0]
            let waiting = shared.pins.isWaiting(port)
            let ok = shared.pins.submit(pin, name: Self.text(req["name"]), port: port)
            plog("host: the phone gave its PIN for the host on \(port): \(ok ? (waiting ? "taken" : "kept for its pairing") : "no such host")")
            return ok ? encode(["ok": true]) : encode(["ok": false, "why": "no Pocket XR host on port \(port)"])
        case "screen-prepare":
            guard let port = Self.number(req["port"]), let i = HostServer.basePorts.firstIndex(of: port) else {
                return encode(["ok": false, "why": "no such screen"])
            }
            let mode = HostScreens.Mode.clamped(Self.number(req["width"]) ?? 1920, Self.number(req["height"]) ?? 1080, Self.number(req["fps"]) ?? 60)
            guard shared.screens.prepare(i + 1, mode) != nil else { return encode(["ok": false, "why": "the virtual screen could not be made"]) }
            return encode(["ok": true, "screen": i + 1])
        case "screens-setup":
            HostPermissions.show(because: "Your phone asked to set this Mac up.", force: true)
            return encode(["ok": true])
        case "status", "start":
            return encode(["ok": true, "pc": computerName, "steam": false, "alvr": false, "steamvr": "off", "os": "mac", "virtual": true])
        default:
            return encode(["ok": false, "why": "unknown request"])
        }
    }

    /// Asks this Mac's user whether [phone] may use it (a minute to answer).
    private func allow(phone: String) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var yes = false
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Let \(phone) show this Mac's screens?"
            a.informativeText = "Pocket XR on the phone wants to show this Mac's screens in the glasses, with its mouse and keyboard. You can take this back with Forget phones in Pocket XR's menu."
            a.addButton(withTitle: "Allow")
            a.addButton(withTitle: "Don't Allow")
            yes = a.runModal() == .alertFirstButtonReturn
            done.signal()
        }
        guard done.wait(timeout: .now() + 60) == .success else { return false }
        return yes
    }

    static func openPermissions() { HostPermissions.show(because: nil, force: true) }
}

/// The two permissions showing this Mac on a phone needs, asked for in one message that names both, each button
/// opening its own pane of System Settings.
enum HostPermissions {
    static let screenPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// Screen Recording (tests with PXR_HOST_TEST=1 go on without it: they send a test picture).
    static var screenAllowed: Bool {
        CGPreflightScreenCaptureAccess() || ProcessInfo.processInfo.environment["PXR_HOST_TEST"] == "1"
    }

    static var inputAllowed: Bool { AXIsProcessTrusted() }

    /// The launch refusal's status_message, which the phone can show as it is.
    static let refusalText = "Pocket XR on the Mac is not allowed to record its screen yet. On the Mac, turn Pocket XR on in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen Pocket XR."

    /// Quits and opens this app again: macOS lets a running app record the screen only after a reopen.
    static func reopen() {
        let path = Bundle.main.bundlePath
        plog("host: reopening Pocket XR (\(path)) so macOS's Screen Recording permission takes effect")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static let lock = NSLock()
    private static var showing = false
    private static var registered = false
    private static var lastShown = Date.distantPast

    /// The message, if something is missing (or [force]), at most once a minute unless forced.
    static func show(because reason: String?, force: Bool = false) {
        lock.lock()
        let screen = CGPreflightScreenCaptureAccess(), input = AXIsProcessTrusted()
        guard !showing, force || ((!screen || !input) && Date().timeIntervalSince(lastShown) > 60) else { lock.unlock(); return }
        showing = true
        lastShown = Date()
        lock.unlock()
        // Puts Pocket XR in the Screen & System Audio Recording list by itself (seen 12:3x: the button alone was not
        // enough, the list showed only the other Pocket XR): both ways of asking, once a run.
        if !screen && !registered {
            registered = true
            _ = CGRequestScreenCaptureAccess()
            Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            plog("host: asked macOS for Screen Recording (so Pocket XR is in its list)")
        }
        DispatchQueue.main.async {
            defer { lock.lock(); showing = false; lastShown = Date(); lock.unlock() }
            var openedScreen = false, openedInput = false
            while true {
                let screen = CGPreflightScreenCaptureAccess(), input = AXIsProcessTrusted()
                if !force && screen && input { return }
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Allow Pocket XR to show this Mac on your phone"
                var lines: [String] = []
                if let reason { lines.append(reason) }
                lines.append("Pocket XR needs two permissions, in System Settings, Privacy & Security:")
                lines.append("• Screen & System Audio Recording, for the picture and sound: \(screen ? "allowed" : "not allowed yet")")
                lines.append("• Accessibility, for your phone's mouse and keys: \(input ? "allowed" : "not allowed yet")")
                lines.append("Turn Pocket XR on in each list. If macOS asks as well, choose Open System Settings. macOS lets Pocket XR record the screen only after it is reopened: once Screen Recording is on, choose Reopen Pocket XR.")
                a.informativeText = lines.joined(separator: "\n\n")
                a.addButton(withTitle: screen ? "Screen Recording: allowed" : "Open Screen Recording")
                a.addButton(withTitle: input ? "Accessibility: allowed" : "Open Accessibility")
                a.addButton(withTitle: "Done")
                if !screen { a.addButton(withTitle: "Reopen Pocket XR") }
                switch a.runModal() {
                case .alertFirstButtonReturn:
                    // Puts Pocket XR in the list (macOS asks once, the first time ever), then opens that pane.
                    if !screen { _ = CGRequestScreenCaptureAccess() }
                    if let u = URL(string: screenPane) { NSWorkspace.shared.open(u) }
                    openedScreen = true
                case .alertSecondButtonReturn:
                    // Puts Pocket XR in the Accessibility list (macOS asks too; its button opens the same pane).
                    if !input { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
                    if let u = URL(string: accessibilityPane) { NSWorkspace.shared.open(u) }
                    openedInput = true
                case .alertThirdButtonReturn:
                    return
                default:
                    reopen()
                    return
                }
                _ = openedInput
            }
        }
    }
}

/// Pocket XR for Mac as the PC end of the phone's PC screens: three host instances, the PC helper's words and the
/// virtual screens, started and stopped together.
final class HostService: @unchecked Sendable {
    private(set) var shared: HostShared?
    private var hosts: [HostServer] = []
    private var helper: HostHelper?
    var isOn: Bool { shared != nil }

    func start() {
        guard shared == nil else { return }
        let name = (Host.current().localizedName ?? "Mac") + " Pocket XR"
        guard let s = HostShared(name: name) else {
            plog("host: not started (no identity)")
            return
        }
        shared = s
        s.pins.ask = { port in Self.askPin(port: port) }
        s.pins.dismiss = { Self.closePinBox() }
        hosts = (1...HostServer.basePorts.count).map { HostServer(index: $0, shared: s) }
        hosts.forEach { $0.start() }
        let h = HostHelper(shared: s)
        h.start()
        helper = h
        s.pins.phoneGivesPin = { [weak h] in h?.running == true }
        plog("host: Screen Recording \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed"), Accessibility \(AXIsProcessTrusted() ? "allowed" : "not allowed")")
        plog("host: \(name) ready (id \(s.identity.uniqueId), \(s.clients.count) paired, H.264\(s.hasHevc ? ", HEVC" : ""), TLS \(s.identity.identity != nil ? "ready" : "missing"))")
    }

    func stop() {
        hosts.forEach { $0.stop() }
        hosts = []
        helper?.stop()
        helper = nil
        shared?.screens.removeAll()
        shared = nil
        plog("host: stopped")
    }

    /// Phones forgotten: none is paired, none is allowed to use the PC helper's words.
    func forgetPhones() {
        shared?.clients.removeAll()
        helper?.forgetPhones()
        plog("host: every phone forgotten")
    }

    static let oldHelperId = "com.hayeco.pocketxr.pchelper"
    static let oldSunshineLabels = ["com.hayeco.pocketxr.sunshine", "com.hayeco.pocketxr.sunshine.2", "com.hayeco.pocketxr.sunshine.3"]

    /// The separate Pocket XR PC helper app is running (it holds port 47610 and runs Sunshine).
    static var oldHelperRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: oldHelperId).isEmpty }

    /// Moving over from the separate PC helper app: asks, then quits it and stops the Sunshines it started (their
    /// launchd jobs), so this app takes port 47610. Nothing is deleted: the apps stay where they are for the user to
    /// move to the Bin.
    @MainActor
    static func offerMoveOver() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Pocket XR now does the PC helper's job"
        a.informativeText = "Your phone shows this Mac through Pocket XR itself now, with no Sunshine. Quit the old Pocket XR PC helper and the Sunshines it runs? Phones it allowed stay allowed. Afterwards you can move Pocket XR PC helper and Sunshine from Applications to the Bin."
        a.addButton(withTitle: "Quit them")
        a.addButton(withTitle: "Not now")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: oldHelperId) { app.terminate() }
        let uid = getuid()
        for label in oldSunshineLabels {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(uid)/\(label)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        plog("host: quit the old Pocket XR PC helper and stopped its Sunshines")
    }

    nonisolated(unsafe) private static var pinBox: NSWindow? // main thread only

    /// The PIN box closed: the PIN came from the phone, or the pairing ended.
    static func closePinBox() {
        DispatchQueue.main.async {
            if let w = pinBox, NSApp.modalWindow === w { NSApp.abortModal() }
        }
    }

    /// The PIN typed on this Mac: a pairing phone shows it.
    static func askPin(port: Int) -> String? {
        let done = DispatchSemaphore(value: 0)
        var pin: String?
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Type the PIN your phone shows"
            a.informativeText = "A phone is pairing with this Mac's PC screen \(HostServer.basePorts.firstIndex(of: port).map { "\($0 + 1)" } ?? "")."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            field.placeholderString = "0000"
            a.accessoryView = field
            a.addButton(withTitle: "Pair")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = field
            pinBox = a.window
            if a.runModal() == .alertFirstButtonReturn { pin = field.stringValue.trimmingCharacters(in: .whitespaces) }
            pinBox = nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        return pin
    }
}
