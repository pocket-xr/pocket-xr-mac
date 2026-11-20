import AppKit
import PocketXRCore

/// PC screens: a Windows PC's screens in the glasses. Each press of the launcher's PC screen button opens the next
/// one, up to one per floating screen and one per Apollo on the PC (the PC setup makes three):
///
/// 1. Moonlight is installed if it is missing, after one question.
/// 2. The PC is found on the local network (its Apollos by mDNS, and the Pocket XR PC helper by broadcast).
/// 3. Moonlight is paired with every Apollo on it that does not know this Mac yet. The PC helper types the PIN into
///    Apollo, so nobody types anything; without the helper Moonlight shows the PIN to type on the PC.
/// 4. Moonlight streams Apollo's "Virtual Display" app (a screen of its own on the PC) full screen on a floating
///    screen that shows no PC screen yet, the one the launcher is on first.
///
/// A PC screen closes when its Moonlight does (Command-Q in it), and every one closes when Pocket XR does.
@MainActor
final class PcScreens {
    struct Open {
        let host: PcHost
        let process: Process
        let displayID: CGDirectDisplayID
    }

    private(set) var open = [Open]()
    private var busy = false
    private var finder: PcFinder?
    private let helper = PcHelper()
    private nonisolated static let lastPcKey = "pcScreens.address"

    var count: Int { open.count }

    /// Opens the next PC screen. [screens] are the floating screens, [preferred] the index of the one the launcher
    /// or the pointer is on. [say] shows a line in the launcher; [done] closes the launcher once Moonlight starts or
    /// the attempt ends.
    func openNext(screens: [VirtualDisplays.Screen], preferred: Int, say: @escaping (String) -> Void, done: @escaping () -> Void) {
        guard !busy else {
            say("A PC screen is on its way.")
            return
        }
        let used = Set(open.map(\.displayID))
        let order = screens.indices.sorted { a, b in (a == preferred ? 0 : 1, a) < (b == preferred ? 0 : 1, b) }
        guard let index = order.first(where: { !used.contains(screens[$0].id) }) else {
            say(screens.count < 3 ? "Every floating screen shows a PC screen. Add a floating screen in Settings for another."
                : "Every floating screen shows a PC screen.")
            return
        }
        let target = screens[index]
        busy = true

        if Moonlight.app == nil {
            done()
            guard askToInstall() else {
                busy = false
                return
            }
            plog("PC screens: installing Moonlight")
            Thread.detachNewThread {
                let result = Moonlight.install(say: { line in plog("Moonlight: \(line)") })
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch result {
                        case .installed:
                            self.find(target: target, index: index, say: say, done: done)
                        case .failed(let why):
                            self.busy = false
                            self.installFailed(why)
                        }
                    }
                }
            }
            return
        }
        find(target: target, index: index, say: say, done: done)
    }

    private func find(target: VirtualDisplays.Screen, index: Int, say: @escaping (String) -> Void, done: @escaping () -> Void) {
        say("Looking for your PC…")
        let running = open.map(\.host.moonlightAddress)
        // mDNS needs the main thread's run loop; the PC helper's broadcast and everything after run on a worker.
        let finder = PcFinder()
        self.finder = finder
        finder.look(seconds: 3) { [weak self] mdns in
            guard let self else { return }
            self.finder = nil
            let helper = self.helper
            Thread.detachNewThread {
                let result = Self.prepare(mdns: mdns, helper: helper, running: Set(running), width: target.width, height: target.height, say: { line in
                    DispatchQueue.main.async { say(line) }
                })
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.busy = false
                        switch result {
                        case .failure(let why):
                            plog("PC screens: \(why.log)")
                            say(why.words)
                        case .success(let ready):
                            self.start(ready, on: target, index: index, say: say)
                            done()
                        }
                    }
                }
            }
        }
    }

    /// Closes every PC screen (Pocket XR is quitting or starting again).
    func closeAll() {
        for o in open where o.process.isRunning { o.process.terminate() }
        if !open.isEmpty { plog("PC screens: closed \(open.count)") }
        open.removeAll()
    }

    // MARK: Moonlight

    private func askToInstall() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Moonlight?"
        alert.informativeText = "Pocket XR shows your PC's screens with Moonlight, a free app (moonlight-stream.org). Pocket XR can download it from its makers on GitHub and put it in your Applications folder. It takes a minute."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            plog("PC screens: Moonlight not installed (Not now)")
            return false
        }
        return true
    }

    private func installFailed(_ why: String) {
        plog("Moonlight: not installed: \(why)")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Moonlight was not installed"
        a.informativeText = why + " You can install it yourself from moonlight-stream.org."
        a.addButton(withTitle: "Open moonlight-stream.org")
        a.addButton(withTitle: "Close")
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: Moonlight.downloadPage) { NSWorkspace.shared.open(u) }
    }

    // MARK: finding and pairing (on a worker thread)

    struct Ready {
        let host: PcHost
        let pcName: String
        let app: String
    }

    struct Trouble: Error {
        let words: String
        let log: String
    }

    private nonisolated static func prepare(mdns: [PcHost], helper: PcHelper, running: Set<String>, width: Int, height: Int, say: @escaping (String) -> Void) -> Result<Ready, Trouble> {
        var hosts = mdns
        let pc = helper.find()
        if let pc {
            plog("PC screens: PC helper on \(pc.name) at \(pc.address)")
            // Its PC's Apollos at the ports the PC setup gives, for a network where mDNS does not get through.
            for port in [PcHostAddress.defaultPort, 48989, 49989] where !hosts.contains(where: { $0.address == pc.address && $0.port == port }) {
                let h = PcHost(name: pc.name, address: pc.address, port: port)
                if let name = PcFinder.serverName(h) { hosts.append(PcHost(name: name, address: pc.address, port: port)) }
            }
        }
        let pcs = PcScreenPick.byPc(hosts)
        guard !pcs.isEmpty else {
            return .failure(Trouble(
                words: "No PC found. On your PC, start Apollo and the Pocket XR PC helper, on the same network as this Mac.",
                log: "no Apollo or Sunshine found (mDNS \(mdns.count), PC helper \(pc == nil ? "none" : "found"))"))
        }
        let last = UserDefaults.standard.string(forKey: lastPcKey)
        let chosen = pcs.first { $0.address == last } ?? pcs.first { $0.address == pc?.address } ?? pcs[0]
        UserDefaults.standard.set(chosen.address, forKey: lastPcKey)
        plog("PC screens: \(chosen.name) at \(chosen.address), Apollos on ports \(chosen.instances.map(\.port))")
        guard let host = PcScreenPick.next(of: chosen.instances, used: running) else {
            return .failure(Trouble(
                words: chosen.instances.count == 1
                    ? "\(chosen.name) gives one PC screen. For more, choose Set up PC screens in the Pocket XR PC helper there."
                    : "Every screen \(chosen.name) gives is open.",
                log: "every Apollo on \(chosen.name) is in use"))
        }
        let helperHere = (pc?.address == chosen.address) ? pc : nil

        // Pairing first, for every Apollo on the PC while no Moonlight streams: each Moonlight saves its list of
        // PCs when it ends, and one started before a pairing could write that pairing away.
        let toCheck = running.isEmpty ? [host] + chosen.instances.filter { $0 != host } : [host]
        var appsOfHost = [String]()
        for h in toCheck {
            var names = Moonlight.apps(h).names
            if names.isEmpty {
                say("Pairing with \(chosen.name)…")
                if let trouble = pair(h, pcName: chosen.name, helper: helperHere, say: say) {
                    if h == host { return .failure(trouble) }
                    plog("PC screens: \(h.moonlightAddress) not paired: \(trouble.log)")
                    continue
                }
                names = Moonlight.apps(h).names
            }
            plog("PC screens: \(h.moonlightAddress) lists \(names)")
            if h == host { appsOfHost = names }
        }
        guard let app = MoonlightCommand.app(from: appsOfHost) else {
            return .failure(Trouble(words: "\(chosen.name) did not let this Mac in. Try again, or pair in Moonlight.",
                                    log: "\(host.moonlightAddress): still no app list after pairing"))
        }
        // A Mac or Linux PC's helper makes a virtual screen per stream: readied at this size before Moonlight
        // connects (its Sunshine checks its encoder on that screen first). The Windows helper refuses it; Apollo
        // makes its own.
        if let pc = helperHere, helper.knows(pc) {
            let start = Date()
            let why = helper.prepareScreen(pc, port: host.port, width: width, height: height, fps: 60)
            plog(String(format: "PC screens: screen-prepare %dx%d@60 on port %d: %@ after %.0f ms", width, height, host.port,
                        why.map { "not ready (\($0))" } ?? "ready", Date().timeIntervalSince(start) * 1000))
        }
        return .success(Ready(host: host, pcName: chosen.name, app: app))
    }

    /// Pairs Moonlight with [host]: the PC helper types the PIN when it can, else Moonlight's window shows it to type
    /// on the PC. Nil when it is paired now.
    private nonisolated static func pair(_ host: PcHost, pcName: String, helper pc: PcHelper.Pc?, say: @escaping (String) -> Void) -> Trouble? {
        var g = SystemRandomNumberGenerator()
        let pin = MoonlightCommand.pin(using: &g)
        guard let process = Moonlight.start(MoonlightCommand.pair(host, pin: pin), label: "Moonlight pair \(host.moonlightAddress)") else {
            return Trouble(words: "Moonlight did not start.", log: "Moonlight pair did not start")
        }
        defer { if process.isRunning { process.terminate() } }
        // Moonlight has to be waiting at its PIN step before Apollo takes the PIN (the helper retries for 10 s).
        Thread.sleep(forTimeInterval: 2)
        var typed = false
        if let pc {
            let helper = PcHelper()
            var allowed = helper.knows(pc)
            if !allowed {
                say("Click Yes on \(pc.name) to let this Mac in.")
                allowed = helper.pair(pc)
            }
            if allowed {
                let why = helper.apolloPin(pc, pin: pin, port: host.port)
                typed = why == nil
                plog("PC screens: PIN through the PC helper for \(host.moonlightAddress): \(why ?? "typed")")
            } else {
                plog("PC screens: not allowed on \(pc.name) by the PC helper")
            }
        }
        if !typed {
            say("Type \(pin) on \(pcName), in Apollo's page (https://localhost:\(host.port + 1)/pin).")
        }
        // Moonlight ends by itself once paired (or after its own message, which is left to it a moment).
        let deadline = Date().addingTimeInterval(typed ? 20 : 120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        return nil
    }

    // MARK: streaming (main thread)

    private func start(_ ready: Ready, on target: VirtualDisplays.Screen, index: Int, say: (String) -> Void) {
        let label = "PC screen \(open.count + 1)"
        let bounds = CGDisplayBounds(target.id)
        // Moonlight opens its window on the screen Qt picks: the pointer is put on the floating screen first.
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        let args = MoonlightCommand.stream(ready.host, app: ready.app, width: target.width, height: target.height, fps: 60)
        plog("\(label): Moonlight \(args.joined(separator: " ")) on floating screen \(index + 1)")
        guard let p = Moonlight.start(args, label: label) else {
            say("Moonlight did not start.")
            return
        }
        say("Opening \(ready.pcName)…")
        let id = target.id
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    plog("\(label): Moonlight ended (\(proc.terminationStatus))")
                    self?.open.removeAll { $0.process === proc }
                }
            }
        }
        open.append(Open(host: ready.host, process: p, displayID: id))
        place(p.processIdentifier, on: id, label: label, tries: 0)
    }

    /// Once Moonlight's window is up: on its floating screen, or moved there (Accessibility), checked each second for
    /// 40 s, since Moonlight first shows a small window while it connects and then the stream's.
    private func place(_ pid: pid_t, on id: CGDirectDisplayID, label: String, tries: Int) {
        guard tries < 40, open.contains(where: { $0.process.processIdentifier == pid }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let bounds = CGDisplayBounds(id)
                if let w = Moonlight.window(of: pid) {
                    let centre = CGPoint(x: w.midX, y: w.midY)
                    if bounds.contains(centre) {
                        if w.size == bounds.size {
                            plog("\(label): Moonlight's window fills its floating screen (\(Int(w.minX)),\(Int(w.minY)) \(Int(w.width))x\(Int(w.height)))")
                            return
                        }
                    } else {
                        // The small window Moonlight shows while it connects is moved too: the stream's window then
                        // opens on the screen it is on.
                        let fills = w.width >= bounds.width * 0.9 && w.height >= bounds.height * 0.9
                        let moved = Moonlight.move(pid: pid, to: bounds, fill: fills)
                        plog("\(label): Moonlight's window at \(Int(w.minX)),\(Int(w.minY)) \(Int(w.width))x\(Int(w.height)), not on its floating screen: \(moved ? "moved there" : AXIsProcessTrusted() ? "could not move it" : "could not move it without Accessibility")")
                    }
                }
                self.place(pid, on: id, label: label, tries: tries + 1)
            }
        }
    }
}
