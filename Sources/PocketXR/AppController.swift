import AppKit
import Metal
import PocketXRCore

/// Pocket XR on the Mac: finds the glasses, makes the virtual displays, captures them, tracks the head and draws the
/// Space on the glasses. Lives in the menu bar.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusLine = NSMenuItem(title: "Looking for glasses…", action: nil, keyEquivalent: "")

    private let device: MTLDevice
    private var renderer: Renderer?
    private var window: GlassesWindow?
    private var displays: VirtualDisplays?
    private var captures = [DisplayCapture]()
    private var glasses: Glasses?
    private var fusion: HeadFusion?
    private var imu: ImuReader?
    private var settings: SettingsControl?
    private var settingsState = SettingsControl.State()
    private var hotKey: HotKey?
    private var quitting = false

    // Settings, kept between runs.
    private var screenCount: Int {
        get { max(1, min(3, defaults.object(forKey: "screens") as? Int ?? 2)) }
        set { defaults.set(newValue, forKey: "screens") }
    }
    private var widthDeg: Double {
        get { defaults.object(forKey: "widthDeg") as? Double ?? SpaceLayout.defaultWidthDeg }
        set { defaults.set(min(SpaceLayout.maxWidthDeg, max(SpaceLayout.minWidthDeg, newValue)), forKey: "widthDeg") }
    }
    private var distance: Double {
        get { defaults.object(forKey: "distance") as? Double ?? SpaceLayout.defaultDistance }
        set { defaults.set(min(SpaceLayout.maxDistance, max(SpaceLayout.minDistance, newValue)), forKey: "distance") }
    }
    private var want3D: Bool {
        get { defaults.object(forKey: "sbs3D") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sbs3D") }
    }
    /// Each eye's vertical field of view: 38 degrees on the Aura (the Deck's number).
    private var fovYDeg: Double { defaults.object(forKey: "fovYDeg") as? Double ?? 38 }

    init(device: MTLDevice) {
        self.device = device
        super.init()
    }

    // MARK: start and stop

    func start() {
        plog("Pocket XR for Mac \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") starting, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        buildMenu()
        hotKey = HotKey(keyCode: 15 /* R */, control: true, option: true) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.recentre() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.screensChanged() }
        }
        if !CGPreflightScreenCaptureAccess() {
            plog("screen recording: not allowed yet; asking")
            CGRequestScreenCaptureAccess()
            setStatus("Allow Pocket XR in System Settings, Privacy & Security, Screen Recording, then open it again.")
        }
        screensChanged()
    }

    /// The glasses' display came, went, or changed mode (a 3D switch re-plugs it).
    private func screensChanged() {
        guard !quitting else { return }
        let usb = UsbDevices.list()
        let found = Glasses.detect(usb)
        if found != glasses {
            plog("glasses: \(found?.name ?? "none") (USB: \(UsbDevices.describe(usb.filter { $0.vendor == Glasses.xreal || $0.vendor == Glasses.viture })))")
            glassesChanged(to: found)
        }
        guard let screen = NSScreen.glasses else {
            if window != nil { plog("glasses display: gone") }
            window?.shut()
            window = nil
            setStatus(glasses == nil ? "Plug in your glasses." : "Waiting for the glasses' display…")
            return
        }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        if let w = window, w.screen == screen, w.frame.size == size { return }
        window?.shut()
        plog("glasses display: \"\(screen.localizedName)\" \(Int(size.width * scale))x\(Int(size.height * scale)), \(screen.maximumFramesPerSecond) Hz")
        ensureDisplays(glassesID: screen.displayID)
        if renderer == nil { renderer = Renderer(device: device, pixelFormat: .bgra8Unorm) }
        let w = GlassesWindow(screen: screen, device: device)
        w.glassesView.onFrame = { [weak self] drawable in self?.frame(drawable) }
        w.orderFrontRegardless()
        window = w
        updateStatus()
    }

    private func glassesChanged(to g: Glasses?) {
        imu?.stop()
        imu = nil
        settings?.stop()
        settings = nil
        fusion = nil
        glasses = g
        guard let g else { return }
        if g.trackingOnMac {
            let f = HeadFusion(axes: g.axes)
            fusion = f
            let r = ImuReader { f.report($0) }
            r.start()
            imu = r
        } else {
            plog("head tracking: not on the Mac yet for \(g.name); the screens are shown flat")
        }
        if g.controlLink {
            let s = SettingsControl(glasses: g) { [weak self] st in
                guard let self else { return }
                Task { @MainActor in self.settingsState = st; self.updateStatus() }
            }
            // Read on the settings thread; the setting lives in UserDefaults, which is thread safe.
            s.want3D = { UserDefaults.standard.object(forKey: "sbs3D") as? Bool ?? true }
            s.start()
            settings = s
        }
    }

    /// The virtual displays and their captures, made once a session (see VirtualDisplays).
    private func ensureDisplays(glassesID: CGDirectDisplayID?) {
        if displays == nil {
            let d = VirtualDisplays(count: screenCount)
            d.arrange(glasses: glassesID)
            displays = d
            for s in d.screens {
                let c = DisplayCapture(displayID: s.id, device: device)
                captures.append(c)
                Task {
                    do { try await c.start(width: s.width, height: s.height) } catch {
                        plog("capture: display \(s.id) did not start: \(error)")
                        await MainActor.run { self.setStatus("Screen Recording isn't allowed. Allow Pocket XR in System Settings, Privacy & Security.") }
                    }
                }
            }
        } else {
            displays?.arrange(glasses: glassesID)
        }
    }

    // MARK: drawing

    private func frame(_ drawable: CAMetalDrawable) {
        guard let renderer, let displays else { return }
        let head = fusion?.view() ?? .identity
        let aspects = displays.screens.map { Double($0.width) / Double($0.height) }
        let placements = SpaceLayout.row(aspects: aspects, widthDeg: widthDeg, distance: distance)
        let panels = zip(placements, captures).map { ($0, $1.texture) }
        renderer.draw(drawable: drawable, head: head, panels: panels, fovYDeg: fovYDeg)
    }

    // MARK: actions

    @objc func recentre() {
        fusion?.recentre()
        plog("recentre")
    }

    @objc private func bigger() { widthDeg += 5; updateMenu() }
    @objc private func smaller() { widthDeg -= 5; updateMenu() }
    @objc private func nearer() { distance -= 0.2; updateMenu() }
    @objc private func further() { distance += 0.2; updateMenu() }

    @objc private func toggle3D() {
        want3D.toggle()
        plog("3D side by side: \(want3D ? "on" : "off")")
        settings?.apply()
        updateMenu()
    }

    @objc private func pickScreens(_ item: NSMenuItem) {
        guard item.tag != screenCount else { return }
        screenCount = item.tag
        // Virtual displays are made once a session (Apple bug FB17797423), so the new count needs a restart.
        let a = NSAlert()
        a.messageText = "Quit and open Pocket XR again to use \(item.tag) screen\(item.tag == 1 ? "" : "s")."
        a.runModal()
        updateMenu()
    }

    @objc private func sendLogs() { SendLogs.run() }

    @objc private func quit() {
        guard !quitting else { return }
        quitting = true
        setStatus("Putting the glasses back…")
        plog("quit")
        captures.forEach { $0.stop() }
        window?.shut()
        imu?.stop()
        guard let s = settings else { NSApp.terminate(nil); return }
        s.restore {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        // Never hang on glasses that stopped answering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { NSApp.terminate(nil) }
    }

    // MARK: menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "visionpro", accessibilityDescription: "Pocket XR")
            ?? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Pocket XR")
        menu.delegate = self
        statusItem.menu = menu
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func updateMenu() {
        menu.removeAllItems()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let r = item("Recentre", #selector(recentre))
        r.toolTip = "Also Control-Option-R from anywhere"
        menu.addItem(r)
        menu.addItem(item("Bigger", #selector(bigger)))
        menu.addItem(item("Smaller", #selector(smaller)))
        menu.addItem(item("Nearer", #selector(nearer)))
        menu.addItem(item("Further", #selector(further)))
        let d3 = item("3D side by side", #selector(toggle3D))
        d3.state = want3D ? .on : .off
        menu.addItem(d3)
        let screens = NSMenuItem(title: "Screens", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for n in 1...3 {
            let i = item("\(n)", #selector(pickScreens(_:)))
            i.tag = n
            i.state = n == screenCount ? .on : .off
            sub.addItem(i)
        }
        screens.submenu = sub
        menu.addItem(screens)
        menu.addItem(.separator())
        menu.addItem(item("Send logs to Mike", #selector(sendLogs)))
        menu.addItem(item("Quit and put the glasses back", #selector(quit), key: "q"))
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
    }

    private func updateStatus() {
        guard let g = glasses else { setStatus("Plug in your glasses."); return }
        var parts = [g.name]
        if g.trackingOnMac { parts.append(imu?.connectedVia != nil ? "head tracking on" : "head tracking starting") }
        if let w = window {
            let px = w.frame.size.width * w.backingScaleFactor
            parts.append("\(Int(px)) wide, \(Int(w.glassesView.fps.rounded())) fps")
        } else {
            parts.append("waiting for its display")
        }
        if settingsState.link {
            if settingsState.ultrawide == 1 { parts.append("Ultrawide") } else if settingsState.stereo == 1 { parts.append("3D") }
            if settingsState.busy { parts.append("changing settings…") }
        }
        setStatus(parts.joined(separator: " · "))
    }
}
