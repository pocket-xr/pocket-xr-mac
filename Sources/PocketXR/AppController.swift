import AVFoundation
import AppKit
import Combine
import Metal
import PocketXRCore
import ServiceManagement

/// Pocket XR on the Mac: finds the glasses, makes the virtual displays, captures them, tracks the head and draws the
/// Space on the glasses. Lives in the menu bar, with a settings window and the tour.
@MainActor
final class AppController: NSObject, NSMenuDelegate, AppActions {
    let store = SettingsStore()
    let state = AppState()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private lazy var settingsWindow = SettingsWindowController(store: store, state: state, actions: self)
    private lazy var tourWindow = TourWindowController(store: store, state: state, actions: self)
    private lazy var controlPanel = ControlPanelController(store: store, state: state, actions: self)
    private lazy var launcher = LauncherController(store: store, state: state, actions: self)
    private let pcScreens = PcScreens()
    private lazy var pocket = PocketMode(state: state, actions: self)
    private lazy var controllerInput = ControllerInput(store: store, state: state, actions: self)
    private lazy var hands = HandTracking(store: store, state: state, actions: self)
    private var panelShownBeforePocket = false
    private var arrangeSoon: DispatchWorkItem?
    private var edgeHint: EdgeHint?
    private var grab: SpaceGrab?

    private let device: MTLDevice
    private var renderer: Renderer?
    private var window: GlassesWindow?
    private var displays: VirtualDisplays?
    private var captures = [DisplayCapture]()
    private var glasses: Glasses?
    private var fusion: HeadFusion?
    private var headPose: HeadPose?
    private var imu: ImuReader?
    private var hidImu: HidImuReader?
    private var settings: SettingsControl?
    private var settingsState = SettingsControl.State()
    private var hotKeys = [HotKey]()
    private var watchers = Set<AnyCancellable>()
    private var statusTimer: Timer?
    private var quitting = false
    private var displaysWereRemoved = false
    /// When the glasses' display was last seen to go, nil while it is there.
    private var glassesGoneSince: Double?
    /// Set by Pocket XR 0.3.0 and earlier when it started itself again with Steady mode on. Now the saved
    /// `steadyOn` setting does that job; a key left behind is read once at start and taken into it.
    private nonisolated static let resumeSteadyKey = "resume_steady"
    /// Steady mode is to come back on for these glasses (the user left it on) and has not been asked yet. Read on the
    /// settings thread too: while it is set, the glasses are left in 2D.
    private let steadyPending = SteadyPending()
    private var resumingSteady = false
    /// When the glasses were last asked to change mode (3D, Steady mode), or Pocket XR started: for a while after,
    /// their display and even their USB connection come and go, and none of that is an unplugging.
    private var modeAskedAt = ProcessInfo.processInfo.systemUptime
    /// Head scroll in Steady mode: the row's slide along the canvas, in the canvas's own degrees.
    private let steadyScroll = HeadScroll()
    private var steadyScrollYaw = 0.0
    /// The canvas is drawn through a narrow lens (see recompute), so a real degree of slide is fewer of its degrees.
    private let steadyScrollScale = 0.6

    /// Head scroll in Steady mode starts from "looking at the middle" again.
    private func resetSteadyScroll() {
        steadyScroll.stop()
        steadyScrollYaw = 0
        headPose?.recentre(yawDeg: 0, followTilt: false)
    }
    private static let displayGoneGraceS = 8.0

    // What a frame needs, worked out when the settings change and not on every frame.
    private var placements = [PanelPlacement]()
    private var trackingOptions = TrackingOptions(SpaceSettings())
    private var renderOptions = RenderOptions()
    private var framePeriod = 1.0 / 60
    /// The screen count and text sharpness the virtual displays were made with.
    private var madeScreens = 0
    private var madeSharper = false
    /// The screen the pointer is on (an index into the virtual displays), nil while it is on the Mac's own screen.
    private var pointerScreen: Int?
    /// Where the head has been pointing, for "Pointer follows head": the screen and since when.
    private var lookedAt: (index: Int, since: Double)?

    init(device: MTLDevice) {
        self.device = device
        super.init()
    }

    // MARK: start and stop

    func start() {
        plog("Pocket XR for Mac \(state.version) starting, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if UserDefaults.standard.bool(forKey: Self.resumeSteadyKey) {
            UserDefaults.standard.removeObject(forKey: Self.resumeSteadyKey)
            store.s.steadyOn = true
        }
        buildMenu()
        registerShortcuts()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.screensChanged() }
        }
        store.$s
            .removeDuplicates()
            .scan((SpaceSettings(), store.s)) { ($0.1, $1) }
            .sink { [weak self] pair in
                // The new value is applied after the store has taken it.
                DispatchQueue.main.async { self?.settingsChanged(from: pair.0, to: pair.1) }
            }
            .store(in: &watchers)
        state.screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        if !state.screenRecordingAllowed {
            plog("screen recording: not allowed yet")
            // A new copy is asked in the tour, where it is explained; one that has seen the tour is asked here.
            if store.s.tourSeen { CGRequestScreenCaptureAccess() }
        }
        recompute()
        screensChanged()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
        if store.s.panelAtStart { openControlPanel() }
        controllerInput.start()
        // The launcher's list of apps is read now, so its first opening is instant.
        _ = launcher.isOpen
        grab = SpaceGrab(
            enabled: { [weak self] in (self?.store.s.grabKeys ?? false) && self?.displays != nil },
            move: { [weak self] yaw, pitch in self?.nudgeSpace(yawDeg: yaw, pitchDeg: pitch) },
            resize: { [weak self] by in
                guard let self else { return }
                var s = self.store.s
                if self.state.steady { s.steadyZoom += by / 40 } else { s.widthDeg += by }
                self.store.s = s.clamped
            })
        if Tour.opensByItself(tourSeen: store.s.tourSeen) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openTour() }
        }
    }

    /// The glasses' display came, went, or changed mode (a 3D switch re-plugs it).
    private func screensChanged() {
        guard !quitting else { return }
        // Pocket XR's own windows stay on the Mac's screen, now and once macOS has finished moving things.
        keepWindowsOnOwnScreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.keepWindowsOnOwnScreen() }
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
            state.displayText = nil
            // 16 Nov 2026 (Mike unplugged the Aura and "the apps wont open on my mac screen anymore as if theres still
            // another monitor connected"): with no glasses the virtual displays cannot be seen, so they go, and macOS
            // moves their windows back to the Mac's own screen. Not at once: a 3D switch takes the glasses' display
            // away for about 4 s (3.6 s seen on the Aura).
            if glassesGoneSince == nil { glassesGoneSince = ProcessInfo.processInfo.systemUptime }
            if displays != nil { checkGlassesStillGone(after: Self.displayGoneGraceS) }
            updateStatus()
            return
        }
        glassesGoneSince = nil
        if displaysWereRemoved, Bundle.main.bundleURL.pathExtension == "app" {
            // Virtual displays made a second time in one session mislead capture (FB17797423, see VirtualDisplays), so
            // the glasses coming back starts Pocket XR afresh.
            plog("glasses display: back; starting Pocket XR again for new virtual displays")
            relaunch()
            return
        }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let wide = Int(size.width * scale), high = Int(size.height * scale)
        framePeriod = 1.0 / Double(max(screen.maximumFramesPerSecond, 30))
        state.displayText = "\(wide) x \(high), \(screen.maximumFramesPerSecond) Hz"
        state.stereo = GlassesOptics.isSideBySide(width: wide, height: high)
        if let w = window, w.screen == screen, w.frame.size == size { return }
        window?.shut()
        plog("glasses display: \"\(screen.localizedName)\" \(wide)x\(high), \(screen.maximumFramesPerSecond) Hz")
        ensureDisplays(glassesID: screen.displayID)
        if renderer == nil { renderer = Renderer(device: device, pixelFormat: .bgra8Unorm) }
        let w = GlassesWindow(screen: screen, device: device)
        w.glassesView.onFrame = { [weak self] drawable in self?.frame(drawable) }
        w.orderFrontRegardless()
        window = w
        recompute()
        updateStatus()
    }

    private func glassesChanged(to g: Glasses?) {
        stopTracking()
        settings?.stop()
        settings = nil
        settingsState = SettingsControl.State()
        glasses = g
        state.glassesName = g?.name
        state.glassesFamily = g?.family
        state.steadyAvailable = g?.steadyCapable ?? false
        state.steady = false
        state.linkOpen = false
        // Steady mode as the user left it comes back once for each connection of glasses that can do it.
        steadyPending.value = store.s.steadyOn && (g?.steadyCapable ?? false) && (g?.controlLink ?? false)
        recompute()
        guard let g else { hands.stop(); return }
        startTracking(g)
        if store.s.handsOn { hands.start() }
        if g.controlLink {
            let s = SettingsControl(glasses: g) { [weak self] st in
                Task { @MainActor in
                    guard let self else { return }
                    let wasSteady = self.settingsState.steady
                    self.settingsState = st
                    self.state.linkOpen = st.link
                    self.state.busy = st.busy
                    self.state.steady = st.steady
                    if wasSteady != st.steady {
                        plog("Steady mode: \(st.steady ? "on" : "off")")
                        self.resetSteadyScroll()
                        self.recompute()
                    }
                    // The user left Steady mode on (before a quit, an unplug, or Pocket XR starting itself again when
                    // a screen is added or removed): back on, once the glasses have settled.
                    if st.steady, self.steadyPending.value, !self.resumingSteady {
                        self.steadyPending.value = false // already on
                    }
                    if st.link, !st.busy, !st.steady, !self.resumingSteady, self.steadyPending.value {
                        self.resumingSteady = true
                        plog("Steady mode: coming back on as it was left, once the glasses have settled")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.resumingSteady = false
                                guard self.steadyPending.value, !self.quitting else { return }
                                self.steadyPending.value = false
                                // Turned off meanwhile: stays off.
                                if self.store.s.steadyOn { self.setSteady(true) }
                            }
                        }
                    }
                    self.updateStatus()
                }
            }
            // Read on the settings thread; the settings live in UserDefaults, which is thread safe.
            // While Steady mode is waiting to come back on, the glasses are left in 2D: a switch to 3D and straight on
            // to Steady mode was too much for the Aura (16 Nov 2026: it answered 5001 three times, then dropped off
            // USB altogether).
            let pending: SteadyPending = steadyPending
            s.want3D = { Self.savedSettings().want3D && !pending.value }
            s.steadySixDof = { Self.savedSettings().steadySixDof }
            s.start()
            settings = s
        }
    }

    /// The settings as last saved, readable from any thread.
    private nonisolated static func savedSettings() -> SpaceSettings {
        guard let data = UserDefaults.standard.data(forKey: SettingsStore.key),
              let s = try? JSONDecoder().decode(SpaceSettings.self, from: data) else { return SpaceSettings() }
        return s
    }

    private func startTracking(_ g: Glasses) {
        let useHid = !g.networkImu && g.hidImu && store.s.hidTracking
        guard g.trackingOnMac || useHid else {
            plog(g.hidImu
                ? "head tracking: \(g.name) uses USB HID, which is an untested switch in Settings; the screens are shown flat"
                : "head tracking: none on the Mac for \(g.name); the screens are shown flat")
            return
        }
        let f = HeadFusion(axes: g.axes)
        fusion = f
        headPose = HeadPose(fusion: f)
        if let a = placements.first?.yawDeg, let b = placements.last?.yawDeg { headPose?.setScrollRange(lowDeg: a, highDeg: b) }
        if useHid {
            let r = HidImuReader(glasses: g) { f.report($0) }
            r.start()
            hidImu = r
        } else {
            let r = ImuReader { f.report($0) }
            r.start()
            imu = r
        }
    }

    private func stopTracking() {
        imu?.stop()
        imu = nil
        hidImu?.stop()
        hidImu = nil
        fusion = nil
        headPose = nil
        state.trackingOn = false
        state.imuHz = 0
    }

    /// Removes the virtual displays once the glasses' display has stayed away long enough: 8 s when the glasses are
    /// unplugged, 25 s while they are still on USB. A change of mode takes their display away and brings it back
    /// more than once (turning Steady mode on, 16 Nov 2026: gone 3 s, back 3 s, gone 4 s), and counting from the
    /// first "gone" alone removed the displays in the middle of it, which started Pocket XR again and undid the mode.
    private func checkGlassesStillGone(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.quitting, self.displays != nil, NSScreen.glasses == nil,
                      let since = self.glassesGoneSince else { return }
                let gone = ProcessInfo.processInfo.systemUptime - since
                let pluggedIn = Glasses.detect(UsbDevices.list()) != nil
                let changingMode = self.state.busy || ProcessInfo.processInfo.systemUptime - self.modeAskedAt < 45
                let limit = (pluggedIn || changingMode) ? 25.0 : Self.displayGoneGraceS
                if gone < limit - 0.2 {
                    self.checkGlassesStillGone(after: min(2, limit - gone))
                    return
                }
                plog("virtual displays: removed, the glasses' display has been gone \(Int(gone)) s")
                // A PC screen would land on the Mac's own screen.
                self.pcScreens.closeAll()
                self.captures.forEach { $0.stop() }
                self.captures = []
                self.displays = nil
                self.displaysWereRemoved = true
                self.state.virtualScreens = 0
                self.state.capturing = 0
            }
        }
    }

    /// The virtual displays and their captures, made once a session (see VirtualDisplays).
    private func ensureDisplays(glassesID: CGDirectDisplayID?) {
        if displays == nil {
            madeScreens = store.s.screens
            madeSharper = store.s.sharperText
            let d = VirtualDisplays(count: madeScreens, hiDPI: madeSharper)
            displays = d
            recompute()
            d.arrange(glasses: glassesID, panels: placements)
            displays = d
            state.virtualScreens = d.screens.count
            state.needsRestart = false
            for s in d.screens {
                let c = DisplayCapture(displayID: s.id, device: device)
                captures.append(c)
                let scale = madeSharper ? 2 : 1
                Task {
                    do { try await c.start(width: s.width * scale, height: s.height * scale) } catch {
                        plog("capture: display \(s.id) did not start: \(error)")
                    }
                }
            }
        } else {
            displays?.arrange(glasses: glassesID, panels: placements)
        }
    }

    // MARK: settings

    private func settingsChanged(from old: SpaceSettings, to new: SpaceSettings) {
        // Screens moved by hand belong to the layout they were moved in: another layout starts tidy. (A saved
        // arrangement brings its own moves with its layout, and those are kept.)
        if old.layout != new.layout, new.screensMoved, old.screenYawDeg == new.screenYawDeg, old.screenPitchDeg == new.screenPitchDeg {
            resetScreenMoves()
            return
        }
        recompute()
        if old.want3D != new.want3D {
            plog("3D side by side: \(new.want3D ? "on" : "off")")
            modeAskedAt = ProcessInfo.processInfo.systemUptime
            settings?.apply()
        }
        if displays != nil {
            state.needsRestart = new.screens != madeScreens || new.sharperText != madeSharper
        }
        if old.shortcuts != new.shortcuts { registerShortcuts() }
        if old.launchAtLogin != new.launchAtLogin { setLaunchAtLogin(new.launchAtLogin) }
        if old.hidTracking != new.hidTracking, let g = glasses, !g.networkImu {
            plog("head tracking over USB HID: \(new.hidTracking ? "on" : "off")")
            stopTracking()
            startTracking(g)
        }
        updateMenu()
    }

    /// Works out the screens' places and how a frame is drawn, from the settings and the glasses.
    private func recompute() {
        let s = store.s
        trackingOptions = TrackingOptions(s)
        let aspects: [Double] = displays?.screens.map { Double($0.width) / Double($0.height) }
            ?? Array(repeating: 16.0 / 9, count: s.screens)
        var fov = GlassesOptics.fovYDeg(glasses: glasses)
        if state.steady {
            // The glasses hold one flat picture themselves, the whole display as one wide canvas (seen on the Aura,
            // 16 Nov 2026: 3840x1080 in Ultrawide, and a left and right eye picture showed every screen twice). The
            // screens are laid in a row that fills it, drawn once, through a narrow lens so they stay near flat.
            fov = 12
            let viewAspect: Double = window.map { Double($0.frame.width / max($0.frame.height, 1)) } ?? 16.0 / 9
            let hfov = 2 * atan(tan(fov * .pi / 360) * viewAspect) * 180 / .pi
            let n = Double(max(aspects.count, 1))
            let gap = s.steadyGapDeg
            // Bigger and smaller in Steady mode: the row drawn larger or smaller on the glasses' picture.
            let each = max(2, (hfov * 0.96 - gap * (n - 1)) / n * s.steadyZoom)
            placements = SpaceLayout.row(aspects: aspects, widthDeg: each, distance: SpaceLayout.defaultDistance, gapDeg: gap)
        } else {
            placements = SpaceLayout.arrange(layout: s.layout, aspects: aspects, widthDeg: s.widthDeg, distance: s.distance, curve: s.curve)
            // Moved by hand: the whole Space turned about the head.
            for i in placements.indices {
                placements[i].yawDeg += s.offsetYawDeg + (i < s.screenYawDeg.count ? s.screenYawDeg[i] : 0)
                placements[i].pitchDeg += s.offsetPitchDeg + (i < s.screenPitchDeg.count ? s.screenPitchDeg[i] : 0)
            }
        }
        state.panels = placements
        state.viewFovYDeg = fov
        let wholeAspect: Double = window.map { Double($0.frame.width / max($0.frame.height, 1)) } ?? 16.0 / 9
        state.viewAspect = (!state.steady && wholeAspect >= 3.2) ? wholeAspect / 2 : wholeAspect
        // The pointer crosses between the displays the way the screens now look (a no-op when nothing moved).
        // Not while a screen is being dragged about: macOS takes half a second to move displays, so it is done
        // once the screens have been still for a moment.
        arrangeSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.displays?.arrange(glasses: NSScreen.glasses?.displayID, panels: self.placements)
            }
        }
        arrangeSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        // Head scroll slides the row no further than its first and last screens.
        if let a = placements.first?.yawDeg, let b = placements.last?.yawDeg { headPose?.setScrollRange(lowDeg: a, highDeg: b) }
        var o = RenderOptions()
        o.fovYDeg = fov
        o.ipd = s.ipdMm / 1000
        o.brightness = s.brightness
        o.glow = s.glow
        o.glowColor = s.glowColor.color
        o.edgeFade = state.steady ? .off : s.edgeFade
        o.mono = state.steady
        o.focused = pointerScreen
        renderOptions = o
    }

    // MARK: drawing

    private func frame(_ drawable: CAMetalDrawable) {
        guard let renderer, displays != nil else { return }
        var head = Quat.identity
        var shown = placements
        // In Steady mode the glasses hold the picture, so the app draws it fixed to the display.
        if !state.steady, let pose = headPose {
            head = pose.drawPose(now: ProcessInfo.processInfo.systemUptime, framePeriod: framePeriod, options: trackingOptions)
            let scroll = pose.scrollYawDeg
            if scroll != 0 {
                for i in shown.indices { shown[i].yawDeg += scroll }
            }
        } else if state.steady, let pose = headPose, store.s.headScroll, store.s.headTracking, shown.count > 1 {
            // Head scroll in Steady mode: the glasses hold the canvas, and the app still knows which way the head
            // has turned since Steady mode came on (or the last Recentre). Past the dead zone the row slides along
            // the canvas, as it does in Smooth Follow. The pose is worked out only to read the turn from it.
            _ = pose.drawPose(now: ProcessInfo.processInfo.systemUptime, framePeriod: framePeriod, options: trackingOptions)
            let look = pose.yawPitchDeg
            let delta = steadyScroll.step(offsetYawDeg: -look.yaw, pitchDeg: look.pitch, dtS: framePeriod) * steadyScrollScale
            let low = min(shown.first?.yawDeg ?? 0, shown.last?.yawDeg ?? 0), high = max(shown.first?.yawDeg ?? 0, shown.last?.yawDeg ?? 0)
            steadyScrollYaw = HeadScroll.clamp(viewYawDeg: steadyScrollYaw, deltaDeg: delta, lowDeg: low, highDeg: high)
            if steadyScrollYaw != 0 {
                for i in shown.indices { shown[i].yawDeg += steadyScrollYaw }
            }
        } else if steadyScrollYaw != 0 {
            steadyScrollYaw = 0
            steadyScroll.stop()
        }
        var panels = [(PanelPlacement, MTLTexture?)]()
        panels.reserveCapacity(shown.count)
        for (i, p) in shown.enumerated() where i < captures.count {
            panels.append((p, captures[i].texture))
        }
        renderer.draw(drawable: drawable, head: head, panels: panels, options: renderOptions)
    }

    // MARK: the pointer, and what the windows show

    /// Four times a second: where the pointer is, what the status says.
    private func tick() {
        guard !quitting else { return }
        trackPointer()
        publishDisplayTiles()
        let trusted = AXIsProcessTrusted()
        if trusted != state.accessibilityAllowed { state.accessibilityAllowed = trusted }
        let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if camera != state.cameraAllowed { state.cameraAllowed = camera }
        updateEdgeHint()
        state.fps = window?.glassesView.fps ?? 0
        state.capturing = captures.filter { $0.texture != nil }.count
        if let pose = headPose, let f = fusion {
            let hz = pose.reportsPerSecond
            state.imuHz = hz
            state.trackingOn = hz > 0
            state.biasReady = f.biasReady
            let yp = pose.yawPitchDeg
            state.yawDeg = yp.yaw
            state.pitchDeg = yp.pitch
        } else {
            state.trackingOn = false
            state.imuHz = 0
        }
        let allowed = CGPreflightScreenCaptureAccess()
        if allowed != state.screenRecordingAllowed { state.screenRecordingAllowed = allowed }
        updateStatus()
    }

    private func trackPointer() {
        guard let screens = displays?.screens, !screens.isEmpty, let at = CGEvent(source: nil)?.location else {
            if pointerScreen != nil { pointerScreen = nil; renderOptions.focused = nil }
            return
        }
        let on = screens.firstIndex { CGDisplayBounds($0.id).contains(at) }
        if on != pointerScreen {
            pointerScreen = on
            renderOptions.focused = on
        }
        if on != nil, !state.pointerVisitedScreen { state.pointerVisitedScreen = true }
        guard store.s.pointerFollowsHead, !state.steady, let pose = headPose, let on else {
            lookedAt = nil
            return
        }
        // The head has to rest on another screen for a moment before the pointer goes there.
        let now = ProcessInfo.processInfo.systemUptime
        let yp = pose.yawPitchDeg
        let head = Quat.aboutY(yp.yaw * .pi / 180) * Quat.aboutX(yp.pitch * .pi / 180)
        guard let hit = LookTarget.hit(head: head, panels: placements), hit.index != on, hit.index < screens.count else {
            lookedAt = nil
            return
        }
        if let l = lookedAt, l.index == hit.index {
            if now - l.since >= 0.45 {
                warpPointer(toScreen: hit.index, u: 0.5, v: 0.5)
                lookedAt = nil
            }
        } else {
            lookedAt = (hit.index, now)
        }
    }

    private func warpPointer(toScreen index: Int, u: Double, v: Double) {
        guard let screens = displays?.screens, index < screens.count else { return }
        let b = CGDisplayBounds(screens[index].id)
        CGWarpMouseCursorPosition(CGPoint(x: b.minX + b.width * u, y: b.minY + b.height * v))
        // Without this the pointer stays frozen for a quarter second after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The pointer goes to the screen the head points at, where it points.
    private func pointerToLookedScreen() {
        guard let pose = headPose, !state.steady else { return }
        let yp = pose.yawPitchDeg
        let head = Quat.aboutY(yp.yaw * .pi / 180) * Quat.aboutX(yp.pitch * .pi / 180)
        guard let hit = LookTarget.hit(head: head, panels: placements) else { return }
        warpPointer(toScreen: hit.index, u: hit.u, v: hit.v)
    }

    // MARK: actions

    func recentre() {
        if state.steady {
            settings?.recentreCanvas()
            resetSteadyScroll()
        } else {
            // Recentre is "in front of me, now": a move by hand is undone first.
            if store.s.offsetYawDeg != 0 || store.s.offsetPitchDeg != 0 {
                store.s.offsetYawDeg = 0
                store.s.offsetPitchDeg = 0
                recompute()
            }
            let middle = SpaceLayout.middle(placements)
            headPose?.recentre(yawDeg: middle.yawDeg, followTilt: store.s.recentreFollowsTilt)
        }
        state.recentred = true
        plog("recentre")
    }

    func adjust(_ a: SpaceAdjust) {
        var s = store.s
        if state.steady {
            // The glasses hold one flat picture: size is the only thing to change, and nearer or further are the
            // same thing to the eye. Layout and curve do not apply.
            switch a {
            case .bigger, .nearer: s.steadyZoom += 0.1
            case .smaller, .further: s.steadyZoom -= 0.1
            case .moreCurve, .lessCurve, .nextLayout: return
            }
            store.s = s.clamped
            return
        }
        switch a {
        case .bigger: s.widthDeg += 5
        case .smaller: s.widthDeg -= 5
        case .nearer: s.distance -= 0.2
        case .further: s.distance += 0.2
        case .moreCurve: s.curve += 0.25
        case .lessCurve: s.curve -= 0.25
        case .nextLayout:
            let choices = SpaceLayout.choices(count: max(state.virtualScreens, 1))
            if let i = choices.firstIndex(of: s.layout) {
                s.layout = choices[(i + 1) % choices.count]
            } else if let first = choices.first {
                s.layout = first
            }
        }
        store.s = s
    }

    /// Every control that turns Steady mode on or off comes here, and the choice is kept for the next start.
    func setSteady(_ on: Bool) {
        guard let settings, state.steadyAvailable else { return }
        plog("Steady mode: asked \(on ? "on" : "off")")
        modeAskedAt = ProcessInfo.processInfo.systemUptime
        // A choice made while Steady mode was waiting to come back on replaces that.
        steadyPending.value = false
        if store.s.steadyOn != on { store.s.steadyOn = on }
        settings.setSteady(on)
    }

    func openTour() { tourWindow.show() }

    func openControlPanel() { controlPanel.show() }

    // MARK: launcher, Pocket mode, hands

    func toggleLauncher() {
        guard let screens = displays?.screens, !screens.isEmpty else { return }
        let id = screens[min(pointerScreen ?? 0, screens.count - 1)].id
        launcher.toggle(on: NSScreen.screens.first { $0.displayID == id })
    }

    func openPcScreen() {
        guard let screens = displays?.screens, !screens.isEmpty else { return }
        // The floating screen the launcher (or the pointer) is on first.
        pcScreens.openNext(screens: screens, preferred: min(pointerScreen ?? 0, screens.count - 1),
                           say: { [weak self] line in self?.launcher.say(line) },
                           done: { [weak self] in self?.launcher.close() })
    }

    @objc private func menuPcScreen() { openPcScreen() }

    func setPocketMode(_ on: Bool) {
        guard on != state.pocketMode else { return }
        // With no floating screen there is nowhere for the pointer to be.
        if on, displays == nil { return }
        plog("Pocket mode: \(on ? "on" : "off")")
        // The control panel is where it was when the Mac's screen comes back (it was found gone, 16 Nov 2026).
        if on { panelShownBeforePocket = controlPanel.isVisible }
        pocket.set(on)
        if !on, panelShownBeforePocket {
            plog("Pocket mode: the control panel was \(controlPanel.isVisible ? "still open" : "gone"), shown again")
            controlPanel.show()
        }
    }

    func setHands(_ on: Bool) {
        plog("hand tracking: asked \(on ? "on" : "off")")
        if on { hands.start() } else { hands.stop() }
    }

    @discardableResult
    func aimPointer(headYawDeg: Double, headPitchDeg: Double) -> Bool {
        // In Steady mode the glasses place the picture themselves, and the app does not know where it sits.
        guard !state.steady, let pose = headPose else { return false }
        let yp = pose.yawPitchDeg
        let head = Quat.aboutY(yp.yaw * .pi / 180) * Quat.aboutX(yp.pitch * .pi / 180)
        let ray = head * (Quat.aboutY(headYawDeg * .pi / 180) * Quat.aboutX(headPitchDeg * .pi / 180))
        guard let hit = LookTarget.hit(head: ray, panels: placements) else { return false }
        warpPointer(toScreen: hit.index, u: hit.u, v: hit.v)
        return true
    }

    @discardableResult
    func placePointer(u: Double, v: Double) -> Bool {
        guard let screens = displays?.screens, !screens.isEmpty else { return false }
        var index = min(pointerScreen ?? 0, screens.count - 1)
        if !state.steady, let pose = headPose {
            let yp = pose.yawPitchDeg
            let head = Quat.aboutY(yp.yaw * .pi / 180) * Quat.aboutX(yp.pitch * .pi / 180)
            if let hit = LookTarget.hit(head: head, panels: placements), hit.index < screens.count { index = hit.index }
        }
        warpPointer(toScreen: index, u: min(max(u, 0.002), 0.998), v: min(max(v, 0.002), 0.998))
        return true
    }

    func pointerButton(down: Bool) {
        guard AXIsProcessTrusted(), let at = CGEvent(source: nil)?.location else { return }
        let e = CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)
        e?.post(tap: .cghidEventTap)
    }

    func pointerScroll(dx: Double, dy: Double) {
        guard AXIsProcessTrusted() else { return }
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func nudgeSpace(yawDeg: Double, pitchDeg: Double) {
        guard !state.steady else { return }
        var s = store.s
        s.offsetYawDeg += yawDeg
        s.offsetPitchDeg += pitchDeg
        store.s = s.clamped
    }

    func nudgeScreen(_ index: Int, yawDeg: Double, pitchDeg: Double) {
        guard !state.steady else { return }
        var s = store.s
        s.moveScreen(index, yawDeg: yawDeg, pitchDeg: pitchDeg)
        store.s = s
    }

    func resetScreenMoves() {
        var s = store.s
        s.screenYawDeg = []
        s.screenPitchDeg = []
        store.s = s
    }

    func movePointer(toScreen index: Int?) {
        if let index {
            warpPointer(toScreen: index, u: 0.5, v: 0.5)
        } else if let own = NSScreen.own?.displayID {
            let b = CGDisplayBounds(own)
            CGWarpMouseCursorPosition(CGPoint(x: b.midX, y: b.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    /// Every display as macOS has it now, for the control panel's map.
    private func publishDisplayTiles() {
        var tiles = [DisplayTile]()
        if let screens = displays?.screens, !screens.isEmpty {
            if let own = NSScreen.own?.displayID {
                tiles.append(DisplayTile(id: -1, title: "This Mac", frame: CGDisplayBounds(own)))
            }
            for (i, s) in screens.enumerated() {
                tiles.append(DisplayTile(id: i, title: "Screen \(i + 1)", frame: CGDisplayBounds(s.id)))
            }
        }
        if tiles != state.displayTiles { state.displayTiles = tiles }
        if state.pointerScreen != pointerScreen { state.pointerScreen = pointerScreen }
    }

    private func keepWindowsOnOwnScreen() {
        controlPanel.keepOnOwnScreen()
        tourWindow.keepOnOwnScreen()
        settingsWindow.keepOnOwnScreen()
    }

    func openSettings() { settingsWindow.show() }

    func sendLogs() { SendLogs.run() }

    func saveGlassesReport() {
        let usb = UsbDevices.list()
        let shown = NSScreen.screens.map { s -> String in
            let scale = s.backingScaleFactor
            return "\(s.localizedName): \(Int(s.frame.width * scale)) x \(Int(s.frame.height * scale)), \(s.maximumFramesPerSecond) Hz"
        }
        let tracking = "\(state.imuHz) reports a second via \(imu?.connectedVia ?? hidImu?.connectedVia ?? "nothing"), bias \(state.biasReady ? "learnt" : "learning")"
        let text = GlassesReport.text(
            appVersion: state.version, system: ProcessInfo.processInfo.operatingSystemVersionString, glasses: glasses,
            usb: usb, links: GlassesNet.routes().map(\.description), displays: shown,
            state: settings == nil ? nil : settingsState, trackingLine: tracking)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let file = folder.appendingPathComponent("Pocket XR glasses report \(stamp).txt")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            plog("glasses report: saved")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            plog("glasses report: not saved: \(error.localizedDescription)")
        }
    }

    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pocket XR settings.json"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exported().write(to: url) } catch { plog("settings: not saved to a file: \(error.localizedDescription)") }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if !store.restore(from: data) {
            let a = NSAlert()
            a.messageText = "That is not a Pocket XR settings file."
            a.runModal()
        }
    }

    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func restartApp() {
        plog("restart asked")
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        // The new copy turns Steady mode back on from the saved choice; Steady mode on now is kept there too.
        if state.steady, !store.s.steadyOn { store.s.steadyOn = true }
        leave { [weak self] in self?.relaunch() }
    }

    func quit() {
        plog("quit")
        leave { NSApp.terminate(nil) }
    }

    /// Stops drawing, puts the glasses back as they were, then calls [then] on the main thread (within 20 s at most).
    private func leave(then: @escaping @MainActor () -> Void) {
        guard !quitting else { return }
        quitting = true
        // Nothing of Pocket XR's is left over the Mac's screen, and the camera is let go.
        pocket.set(false)
        launcher.close()
        pcScreens.closeAll()
        hands.stop()
        state.statusLine = "Putting the glasses back…"
        updateMenu()
        captures.forEach { $0.stop() }
        window?.shut()
        stopTracking()
        var done = false
        let finish: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            then()
        }
        guard let s = settings else { finish(); return }
        s.restore { DispatchQueue.main.async { MainActor.assumeIsolated { finish() } } }
        // Never hang on glasses that stopped answering. Leaving Steady mode takes more steps, so it gets longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + (state.steady ? 30 : 20)) { MainActor.assumeIsolated { finish() } }
    }

    private func relaunch() {
        quitting = true
        pcScreens.closeAll()
        stopTracking()
        settings?.stop()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundleURL.path]
        try? open.run()
        NSApp.terminate(nil)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            plog("open at login: \(on ? "on" : "off")")
        } catch {
            plog("open at login: macOS refused: \(error.localizedDescription)")
        }
    }

    // MARK: shortcuts

    private func registerShortcuts() {
        hotKeys.removeAll()
        var taken = Set<String>()
        if store.s.shortcuts, !shortcutsPaused {
            for sc in Shortcut.all {
                let id = sc.id
                if let k = HotKey(keyCode: sc.keyCode, modifiers: sc.modifiers, action: { [weak self] in
                    Task { @MainActor in self?.shortcut(id) }
                }) {
                    hotKeys.append(k)
                } else {
                    plog("shortcut \(sc.keys) (\(sc.title)): macOS would not register it")
                    taken.insert(id)
                }
            }
        }
        if !shortcutsPaused, taken != state.shortcutsTaken { state.shortcutsTaken = taken }
    }

    /// True while Settings is waiting for new keys: every shortcut is let go meanwhile.
    private var shortcutsPaused = false

    func pauseShortcuts(_ paused: Bool) {
        guard paused != shortcutsPaused else { return }
        shortcutsPaused = paused
        registerShortcuts()
    }

    func changeShortcut(id: String, keyCode: UInt32, modifiers: UInt32, label: String) -> String? {
        guard let sc = Shortcut.all.first(where: { $0.id == id }) else { return nil }
        guard modifiers & (Shortcut.control | Shortcut.option | Shortcut.command) != 0 else {
            return "Use Control, Option or Command with it."
        }
        if let clash = Shortcut.all.first(where: { $0.id != id && $0.keyCode == keyCode && $0.modifiers == modifiers }) {
            return "\(label) is already \(clash.title)."
        }
        // Pocket XR's own keys are let go first, so a refusal here is someone else's. The test key goes as soon as it
        // is made (HotKey lets go of its keys when it goes).
        hotKeys.removeAll()
        let free: Bool = HotKey(keyCode: keyCode, modifiers: modifiers, action: {}) != nil
        if !free {
            registerShortcuts()
            return "macOS would not give Pocket XR \(label): another app may use it. Choose other keys."
        }
        let usual: Bool = keyCode == sc.usualKeyCode && modifiers == (Shortcut.control | Shortcut.option)
        ShortcutChoices.set(id, usual ? nil : ShortcutChoice(keyCode: keyCode, modifiers: modifiers, label: label))
        plog("shortcut \(sc.title): now \(label)")
        registerShortcuts()
        state.shortcutsVersion += 1
        updateMenu()
        return nil
    }

    func resetShortcut(_ id: String?) {
        if let id {
            ShortcutChoices.set(id, nil)
        } else {
            ShortcutChoices.resetAll()
        }
        plog("shortcut \(id ?? "every one"): back to the usual keys")
        registerShortcuts()
        state.shortcutsVersion += 1
        updateMenu()
    }

    private func shortcut(_ id: String) {
        switch id {
        case "recentre": recentre()
        case "steady": setSteady(!state.steady)
        case "launcher": toggleLauncher()
        case "pocket": setPocketMode(!state.pocketMode)
        case "hands": setHands(!state.handsRunning)
        case "bigger": adjust(.bigger)
        case "smaller": adjust(.smaller)
        case "nearer": adjust(.nearer)
        case "further": adjust(.further)
        case "moreCurve": adjust(.moreCurve)
        case "lessCurve": adjust(.lessCurve)
        case "layout": adjust(.nextLayout)
        case "depth": store.s.want3D.toggle()
        case "pointer": pointerToLookedScreen()
        default: break
        }
    }

    // MARK: menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "visionpro", accessibilityDescription: "Pocket XR")
            ?? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Pocket XR")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
        updateMenu()
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", on: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.isEnabled = enabled && action != nil
        if let on { i.state = on ? .on : .off }
        return i
    }

    private func shortcutHint(_ id: String) -> String {
        guard store.s.shortcuts, let s = Shortcut.all.first(where: { $0.id == id }) else { return "" }
        return "   \(s.keys)"
    }

    private func updateMenu() {
        menu.removeAllItems()
        let s = store.s
        let status = NSMenuItem(title: state.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if state.needsRestart {
            menu.addItem(item("Restart Pocket XR for the new screens", #selector(menuRestart)))
        }
        menu.addItem(item("Open the control panel", #selector(menuPanel)))
        menu.addItem(item("Launcher" + shortcutHint("launcher"), #selector(menuLauncher), on: state.launcherOpen, enabled: state.virtualScreens > 0))
        menu.addItem(item("Open a PC screen", #selector(menuPcScreen), enabled: state.virtualScreens > 0))
        menu.addItem(item("Pocket mode" + shortcutHint("pocket"), #selector(menuPocket), on: state.pocketMode, enabled: state.virtualScreens > 0))
        menu.addItem(item("Hand tracking" + shortcutHint("hands"), #selector(menuHands), on: state.handsRunning))
        menu.addItem(.separator())
        menu.addItem(item("Recentre" + shortcutHint("recentre"), #selector(menuRecentre)))
        menu.addItem(item("Steady mode" + shortcutHint("steady"), #selector(menuSteady), on: state.steady, enabled: state.steadyAvailable && state.linkOpen))
        menu.addItem(item("3D side by side" + shortcutHint("depth"), #selector(menu3D), on: s.want3D))
        menu.addItem(.separator())

        let layout = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu()
        let count = max(state.virtualScreens, s.screens)
        for l in SpaceLayout.choices(count: count) {
            let i = item(SpaceLayout.title(l, count: count), #selector(menuLayout(_:)), on: l == s.layout)
            i.representedObject = l.rawValue
            layoutMenu.addItem(i)
        }
        layout.submenu = layoutMenu
        menu.addItem(layout)
        menu.addItem(item("Bigger" + shortcutHint("bigger"), #selector(menuBigger)))
        menu.addItem(item("Smaller" + shortcutHint("smaller"), #selector(menuSmaller)))
        menu.addItem(item("Nearer" + shortcutHint("nearer"), #selector(menuNearer)))
        menu.addItem(item("Further" + shortcutHint("further"), #selector(menuFurther)))
        menu.addItem(item("More curve" + shortcutHint("moreCurve"), #selector(menuMoreCurve)))
        menu.addItem(item("Less curve" + shortcutHint("lessCurve"), #selector(menuLessCurve)))

        let tracking = NSMenuItem(title: "Tracking", action: nil, keyEquivalent: "")
        let trackingMenu = NSMenu()
        for m in TrackingMode.allCases {
            let i = item(m.title, #selector(menuTracking(_:)), on: s.headTracking && m == s.trackingMode)
            i.representedObject = m.rawValue
            trackingMenu.addItem(i)
        }
        trackingMenu.addItem(.separator())
        trackingMenu.addItem(item("Head tracking", #selector(menuHeadTracking), on: s.headTracking))
        tracking.submenu = trackingMenu
        menu.addItem(tracking)

        let screens = NSMenuItem(title: "Screens", action: nil, keyEquivalent: "")
        let screensMenu = NSMenu()
        for n in SpaceSettings.screensRange {
            let i = item("\(n)", #selector(menuScreens(_:)), on: n == s.screens)
            i.tag = n
            screensMenu.addItem(i)
        }
        screens.submenu = screensMenu
        menu.addItem(screens)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(menuSettings), key: ","))
        menu.addItem(item("Tour of Pocket XR", #selector(menuTour)))
        menu.addItem(item("Send logs to Mike", #selector(menuSendLogs)))
        menu.addItem(.separator())
        menu.addItem(item("Quit and put the glasses back", #selector(menuQuit), key: "q"))
    }

    @objc private func menuPanel() { openControlPanel() }
    @objc private func menuLauncher() { toggleLauncher() }
    @objc private func menuPocket() { setPocketMode(!state.pocketMode) }
    @objc private func menuHands() { setHands(!state.handsRunning) }
    @objc private func menuRecentre() { recentre() }

    /// The glowing tab on the edge of the Mac's screen that the floating screens lie beyond, until the pointer has
    /// been across once this session.
    private func updateEdgeHint() {
        let tiles = state.displayTiles
        guard !state.pointerVisitedScreen, let own = tiles.first(where: { $0.isOwn }),
              let first = tiles.first(where: { !$0.isOwn && $0.frame.minX >= own.frame.maxX - 1 && $0.frame.minY < own.frame.maxY && $0.frame.maxY > own.frame.minY }),
              let screen = NSScreen.own else {
            edgeHint?.close()
            edgeHint = nil
            return
        }
        _ = first
        if edgeHint == nil { edgeHint = EdgeHint() }
        edgeHint?.show(onRightEdgeOf: screen)
    }
    @objc private func menuSteady() { setSteady(!state.steady) }
    @objc private func menu3D() { store.s.want3D.toggle() }
    @objc private func menuBigger() { adjust(.bigger) }
    @objc private func menuSmaller() { adjust(.smaller) }
    @objc private func menuNearer() { adjust(.nearer) }
    @objc private func menuFurther() { adjust(.further) }
    @objc private func menuMoreCurve() { adjust(.moreCurve) }
    @objc private func menuLessCurve() { adjust(.lessCurve) }
    @objc private func menuHeadTracking() { store.s.headTracking.toggle() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuTour() { openTour() }
    @objc private func menuSendLogs() { sendLogs() }
    @objc private func menuRestart() { restartApp() }
    @objc private func menuQuit() { quit() }

    @objc private func menuLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = ArrangeLayout(rawValue: raw) else { return }
        store.s.layout = l
    }

    @objc private func menuTracking(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = TrackingMode(rawValue: raw) else { return }
        var s = store.s
        s.headTracking = true
        s.trackingMode = m
        store.s = s
    }

    @objc private func menuScreens(_ sender: NSMenuItem) {
        store.s.screens = sender.tag
    }

    // MARK: status

    private func updateStatus() {
        guard !quitting else { return }
        let line: String
        if let name = state.glassesName {
            var parts = [name]
            if window == nil {
                parts.append("waiting for its display")
            } else {
                if !state.screenRecordingAllowed {
                    parts.append("allow Screen Recording to see your screens")
                } else if state.steady {
                    parts.append("Steady mode")
                } else if state.trackingOn {
                    parts.append("head tracking on")
                } else if headPose != nil {
                    parts.append("head tracking starting")
                }
                if state.stereo && !state.steady { parts.append("3D") }
                parts.append("\(Int(state.fps.rounded())) fps")
            }
            if state.busy { parts.append("changing settings…") }
            line = parts.joined(separator: " · ")
        } else {
            line = "Plug in your glasses."
        }
        if line != state.statusLine { state.statusLine = line }
    }
}

/// A yes or no read on the main thread and the settings thread.
final class SteadyPending: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return on
        }
        set {
            lock.lock()
            on = newValue
            lock.unlock()
        }
    }
}
