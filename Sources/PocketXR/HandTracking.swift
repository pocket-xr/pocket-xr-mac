import AppKit
import AVFoundation
import Combine
import PocketXRCore
import SwiftUI

// Hand tracking: the glasses' camera sees the hands, a ray from the camera through a steady point on the knuckles
// aims the pointer, and a pinch clicks. This file joins the parts: the camera and detector (HandCamera.swift), the
// logic (PocketXRCore/Hand*.swift), the app's actions, the settings (HandSettings.swift) and the calibration
// (HandCalibrationWindow.swift).
//
// NOTHING here has been tried on a Mac with glasses. XREAL's firmware 16.1.04 and later turns the Aura's camera off
// for hosts, so on many glasses no camera will be found, and the windows say so.

/// One camera in the settings' list.
struct HandsCameraItem: Identifiable, Equatable {
    let choice: HandCameraChoice
    let name: String
    var id: String { choice.stored }
}

/// What hand tracking keeps for itself in the Mac's defaults, apart from the app's settings (which camera, the
/// hand ray's calibration with a line about how it went, the air trackpad's reach), and what it knows about the
/// cameras now, for the settings window to show.
final class HandsPrefs: ObservableObject {
    static let shared = HandsPrefs(defaults: .standard)
    static let cameraKey = "hands_camera"
    static let calibrationKey = "hands_calibration"
    static let resultKey = "hands_calibration_result"
    static let reachKey = "hands_reach_centre"

    private let defaults: UserDefaults?

    /// Which camera to use: the glasses' own (the Mac's when the glasses have none), the Mac's, or one device.
    @Published var camera: HandCameraChoice {
        didSet { defaults?.set(camera.stored, forKey: Self.cameraKey) }
    }

    /// The hand ray's correction, nil before any calibration and after a reset.
    @Published var calibration: HandCalibration? {
        didSet {
            if let calibration {
                defaults?.set(calibration.numbers, forKey: Self.calibrationKey)
            } else {
                defaults?.removeObject(forKey: Self.calibrationKey)
            }
        }
    }

    /// How the last calibration went, in one line.
    @Published var lastResult: String? {
        didSet {
            if let lastResult {
                defaults?.set(lastResult, forKey: Self.resultKey)
            } else {
                defaults?.removeObject(forKey: Self.resultKey)
            }
        }
    }

    /// The air trackpad's reach: the middle of its box in the camera's picture, nil for where it rests.
    @Published var reachCentre: HandPoint? {
        didSet {
            if let reachCentre {
                defaults?.set([reachCentre.x, reachCentre.y], forKey: Self.reachKey)
            } else {
                defaults?.removeObject(forKey: Self.reachKey)
            }
        }
    }

    /// The dots are up now (the hand ray's calibration).
    @Published var calibrating = false
    /// Waiting for the pinch that sets the air trackpad's reach.
    @Published var settingReach = false
    /// The cameras that are not the glasses', as macOS lists them now.
    @Published var cameras = [HandsCameraItem]()
    /// The glasses have a camera macOS can open.
    @Published var glassesFound = false
    /// The camera the choice comes to faces the person: the air trackpad, not the hand ray.
    @Published var facing = false
    /// The glasses' camera was chosen, there is none, and the Mac's is used in its place.
    @Published var fellBack = false
    /// The name of the camera the choice comes to, nil when there is none.
    @Published var cameraName: String?

    var airBox: HandAirBox { HandAirBox(centre: reachCentre ?? HandAirBox.restCentre) }

    /// [defaults] nil keeps everything in memory only (the pictures rendered to files).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        camera = HandCameraChoice(stored: defaults?.string(forKey: Self.cameraKey))
        let numbers: [Double]? = (defaults?.array(forKey: Self.calibrationKey) as? [NSNumber])?.map { $0.doubleValue }
        calibration = numbers.flatMap { HandCalibration(numbers: $0) }
        lastResult = defaults?.string(forKey: Self.resultKey)
        let reach: [Double]? = (defaults?.array(forKey: Self.reachKey) as? [NSNumber])?.map { $0.doubleValue }
        if let reach, reach.count == 2, reach.allSatisfy({ $0.isFinite }) {
            reachCentre = HandPoint(x: reach[0], y: reach[1])
        } else {
            reachCentre = nil
        }
    }
}

/// The camera's picture for the settings window, while it is showing with a camera that faces the person: a small
/// mirrored copy about 10 times a second, with where the hand's steady point is.
final class HandsPreview: ObservableObject {
    static let shared = HandsPreview()
    @Published var picture: CGImage?
    /// The tracked point in the (mirrored) picture, nil with no hand.
    @Published var point: HandPoint?
    /// The settings window is showing the preview now.
    var watching = false
}

/// Hand tracking from the glasses' camera.
@MainActor
final class HandTracking {
    /// The one hand tracker, for the settings' buttons that the app's actions have no call for (calibrate, reset).
    static weak var current: HandTracking?

    enum Line {
        static let looking = "Looking for the glasses' camera"
        static let noCamera = "No camera found on these glasses"
        static let lookingAny = "Looking for the camera"
        static let noCameraAny = "No camera found"
        static let notAllowed = "The camera is not allowed yet"
        static let watching = "Watching for your hands"
        static let dark = "The camera's picture is black. Is its lens covered, or the room dark?"
        static let steady = "Hands do not aim in Steady mode"
        static let noOpen = "The camera could not be opened"
    }

    /// A camera is looked for every 3 seconds for up to 30, then hand tracking stops with the reason showing.
    private static let retrySeconds = 3.0
    private static let giveUpSeconds = 30.0
    /// A calibration with no pinch for this long is put away.
    private static let calibrationIdleSeconds = 30.0

    private let store: SettingsStore
    private let state: AppState
    private weak var actions: AppActions?
    private let prefs: HandsPrefs

    private var running = false
    private var camera: HandCamera?
    private var waitTimer: Timer?
    private var waitingSince = 0.0
    private var watchers = Set<AnyCancellable>()
    private var deviceWatches = [NSObjectProtocol]()
    private let preview = HandsPreview.shared
    /// Waiting for the pinch that sets the air trackpad's reach.
    private var reachTimer: Timer?

    private let primary = HandPrimary()
    private let anchor = HandAnchor()
    private let filter = HandRayFilter()
    private let gestures = HandGestures()
    private var buttonDown = false
    private var aimMode = HandAim.handRay
    private var lastFrameMs = 0.0
    /// Look and pinch: the head aims the pointer now (a hand is seen and no pinch is holding the pointer still).
    private var headAims = false
    private var headTimer: Timer?

    private var run: HandCalibrationRun?
    private var runScreen = 0
    private var runWindow: HandCalibrationWindow?
    private var runTimer: Timer?

    init(store: SettingsStore, state: AppState, actions: AppActions) {
        self.store = store
        self.state = state
        self.actions = actions
        self.prefs = HandsPrefs.shared
        HandTracking.current = self
        // Another camera chosen: start again with it.
        prefs.$camera.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.cameraChoiceChanged() }
            }
        }.store(in: &watchers)
        // Cameras come and go (glasses plugged in, an iPhone nearby): keep the list and the camera in use current.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let watch = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let gone: String? = name == AVCaptureDevice.wasDisconnectedNotification ? (note.object as? AVCaptureDevice)?.uniqueID : nil
                MainActor.assumeIsolated { self?.camerasChanged(gone: gone) }
            }
            deviceWatches.append(watch)
        }
        refreshCameras()
    }

    /// Lists the cameras afresh and works out which one the choice comes to. Returns that camera.
    @discardableResult
    func refreshCameras() -> AVCaptureDevice? {
        let items: [HandsCameraItem] = HandCamera.otherCameras().map { device in
            // The Mac's built-in camera is the "mac" choice; any other is kept by its id.
            let builtIn: Bool = device.deviceType == .builtInWideAngleCamera
            return HandsCameraItem(choice: builtIn ? .mac : .device(device.uniqueID), name: device.localizedName)
        }
        let glasses: Bool = HandCamera.glassesCamera() != nil
        let resolved = HandCamera.resolve(prefs.camera)
        let facing: Bool = resolved.device.map { !HandCamera.isGlasses($0) } ?? (prefs.camera != .glasses)
        if prefs.cameras != items { prefs.cameras = items }
        if prefs.glassesFound != glasses { prefs.glassesFound = glasses }
        if prefs.facing != facing { prefs.facing = facing }
        if prefs.fellBack != resolved.fellBack { prefs.fellBack = resolved.fellBack }
        if prefs.cameraName != resolved.device?.localizedName { prefs.cameraName = resolved.device?.localizedName }
        if state.handsCameraFound != (resolved.device != nil) { state.handsCameraFound = resolved.device != nil }
        return resolved.device
    }

    private func camerasChanged(gone: String?) {
        if let gone, let camera, camera.id == gone {
            cameraUnplugged()
            return
        }
        let now: AVCaptureDevice? = refreshCameras()
        // The glasses' camera has come while the Mac's stood in for it: change over.
        if running, let camera, let now, now.uniqueID != camera.id {
            plog("hands: \(now.localizedName) is there now, changing over")
            closeCamera()
            waitingSince = CACurrentMediaTime()
            lookForCamera()
            if running && self.camera == nil { startWaiting() }
        }
    }

    var isRunning: Bool { running }

    // MARK: starting and stopping

    func start() {
        guard !running else { return }
        running = true
        waitingSince = CACurrentMediaTime()
        if !state.handsRunning { state.handsRunning = true }
        plog("hands: starting (\(store.s.handAim.rawValue))")
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                plog("hands: camera \(allowed ? "allowed" : "not allowed")")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.lookForCamera() }
                }
            }
        }
        lookForCamera()
        if running && camera == nil { startWaiting() }
    }

    func stop() {
        let was: Bool = running
        running = false
        stopWaiting()
        endCalibration(nil)
        closeCamera()
        if was { plog("hands: stopped") }
        if state.handsRunning { state.handsRunning = false }
        if state.handsSeen != 0 { state.handsSeen = 0 }
        setStatus("")
    }

    private func startWaiting() {
        stopWaiting()
        let t = Timer(timeInterval: Self.retrySeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForCamera() }
        }
        RunLoop.main.add(t, forMode: .common)
        waitTimer = t
    }

    private func stopWaiting() {
        waitTimer?.invalidate()
        waitTimer = nil
    }

    /// One look for the camera to use. Opens it when there is one and it is allowed; otherwise says what is
    /// missing and, after 30 seconds of that, stops.
    private func lookForCamera() {
        let device: AVCaptureDevice? = refreshCameras()
        guard running, camera == nil else { return }
        let allowed: Bool = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let ofGlasses: Bool = prefs.camera == .glasses
        var waitingLine: String = ofGlasses ? Line.looking : Line.lookingAny
        var finalLine: String = ofGlasses ? Line.noCamera : Line.noCameraAny
        if let device {
            if allowed {
                if open(device) { return }
                waitingLine = Line.noOpen
                finalLine = Line.noOpen
            } else {
                waitingLine = Line.notAllowed
                finalLine = Line.notAllowed
            }
        }
        if CACurrentMediaTime() - waitingSince >= Self.giveUpSeconds {
            plog("hands: gave up after \(Int(Self.giveUpSeconds)) s: \(finalLine)")
            running = false
            stopWaiting()
            if state.handsRunning { state.handsRunning = false }
            setStatus(finalLine)
        } else {
            setStatus(waitingLine)
        }
    }

    private func open(_ device: AVCaptureDevice) -> Bool {
        guard let opened = HandCamera(device: device) else { return false }
        opened.onFrame = { [weak self, weak opened] frame in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let opened, self.camera === opened else { return }
                    self.handle(frame)
                }
            }
        }
        opened.onPreview = { [weak self, weak opened] picture in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let opened, self.camera === opened, self.preview.watching else { return }
                    self.preview.picture = picture
                }
            }
        }
        camera = opened
        stopWaiting()
        startAfresh()
        aimMode = store.s.handAim
        opened.start()
        setStatus(steadyStopsAim(facing: opened.facing) ? Line.steady : Line.watching)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.headAimTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        headTimer = t
        return true
    }

    /// In Steady mode the app does not know where the picture sits, so nothing that aims by angle can aim. The air
    /// trackpad places the pointer on a screen by shares of it, and still works.
    private func steadyStopsAim(facing: Bool) -> Bool {
        state.steady && !(facing && store.s.handAim == .handRay)
    }

    private func closeCamera() {
        headTimer?.invalidate()
        headTimer = nil
        camera?.stop()
        camera = nil
        endReach()
        if preview.picture != nil { preview.picture = nil }
        if preview.point != nil { preview.point = nil }
        letGo()
        startAfresh()
    }

    /// The camera went (the glasses were unplugged, or their camera turned off): look for it again, for 30 seconds.
    private func cameraUnplugged() {
        guard running, camera != nil else { return }
        plog("hands: the camera went away")
        endCalibration("Calibration stopped: the camera went away.")
        closeCamera()
        if state.handsSeen != 0 { state.handsSeen = 0 }
        waitingSince = CACurrentMediaTime()
        lookForCamera()
        if running && camera == nil { startWaiting() }
    }

    private func cameraChoiceChanged() {
        refreshCameras()
        guard running else { return }
        plog("hands: the camera to use changed, starting again")
        stop()
        start()
    }

    private func startAfresh() {
        primary.reset()
        anchor.reset()
        filter.reset()
        gestures.reset(waitForOpen: true)
        headAims = false
    }

    /// Lets the mouse button go if a pinch has it down.
    private func letGo() {
        guard buttonDown else { return }
        buttonDown = false
        actions?.pointerButton(down: false)
    }

    private func setStatus(_ line: String) {
        if state.handsStatus != line { state.handsStatus = line }
    }

    // MARK: each frame

    private func handle(_ frame: HandCameraFrame) {
        guard running, let camera else { return }
        lastFrameMs = frame.timeMs
        let look: Bool = store.s.handAim == .lookAndPinch
        if store.s.handAim != aimMode {
            // The way of aiming changed under a hand: let go and start afresh, so nothing is left half done.
            aimMode = store.s.handAim
            letGo()
            startAfresh()
        }
        if run != nil && (state.steady || look) {
            endCalibration("Calibration stopped: it needs the hand ray, and not Steady mode.")
        }
        // A camera that faces the person: the air trackpad. The hand's place in the picture places the pointer.
        let air: Bool = camera.facing && !look
        camera.previewWanted = camera.facing && preview.watching

        let which: Int? = primary.choose(frame.hands.map { $0.centre }, timeMs: frame.timeMs)
        var input: HandInput?
        if let which {
            let hand: HandPoints = frame.hands[which]
            let point: HandPoint = anchor.point(hand, timeMs: frame.timeMs)
            let aim: HandAngles
            if air {
                let place = prefs.airBox.place(point)
                aim = filter.filter(HandAirBox.angles(u: place.u, v: place.v), timeMs: frame.timeMs)
            } else {
                let model = HandCameraModel(fovDeg: camera.fovDeg, aspect: frame.aspect)
                let smooth: HandAngles = filter.filter(model.ray(point), timeMs: frame.timeMs)
                // While the dots are up the ray is used as the camera gives it: that is what is being measured.
                let correction: HandCalibration = run == nil ? (prefs.calibration ?? .identity) : .identity
                aim = look ? .zero : correction.apply(smooth)
            }
            if preview.watching { preview.point = point }
            let motion: HandAngles = look ? HandAngles(yawDeg: state.yawDeg, pitchDeg: state.pitchDeg) : aim
            input = HandInput(ratio: hand.pinchRatio, palmFacing: HandPalm.towardFace(hand, cameraFacesYou: camera.facing), aim: aim, motion: motion)
        } else if preview.point != nil {
            preview.point = nil
        }
        for event in gestures.update(input, timeMs: frame.timeMs) {
            act(on: event, look: look, air: air)
        }
        headAims = look && which != nil && !gestures.holdsPointer

        let seen: Int = min(frame.hands.count, 2)
        if state.handsSeen != seen { state.handsSeen = seen }
        if steadyStopsAim(facing: camera.facing) {
            setStatus(Line.steady)
        } else {
            // A black picture finds no hand however long it is watched: say so (the MacBook Air's own camera gave
            // one, light 0 of 255, on 16 Nov 2026, and "Watching for your hands" told the user nothing).
            let waiting: String = camera.dark ? Line.dark : Line.watching
            setStatus(seen == 0 ? waiting : (seen == 1 ? "1 hand" : "2 hands"))
        }
    }

    private func act(on event: HandEvent, look: Bool, air: Bool) {
        switch event {
        case .aim(let at):
            if air {
                let place = HandAirBox.shares(at)
                actions?.placePointer(u: place.u, v: place.v)
            } else if !look {
                // When the head aims, the 30 a second timer does it, so the pointer is as smooth as the head.
                actions?.aimPointer(headYawDeg: at.yawDeg, headPitchDeg: at.pitchDeg)
            }
        case .press(let at):
            if run != nil {
                calibrationPinch(at)
            } else if prefs.settingReach {
                reachPinch(at, air: air)
            } else {
                buttonDown = true
                actions?.pointerButton(down: true)
            }
        case .release:
            letGo()
        case .toggleLauncher:
            if run == nil && !prefs.settingReach {
                plog("hands: palm pinch, launcher")
                actions?.toggleLauncher()
            }
        case .recentre:
            if run == nil && !prefs.settingReach {
                plog("hands: palm pinch held, recentre")
                actions?.recentre()
            }
        case .handLost:
            anchor.reset()
            filter.reset()
        }
    }

    /// Look and pinch: the pointer goes where the head points, 30 times a second, while a hand is seen.
    private func headAimTick() {
        guard running, headAims, store.s.handAim == .lookAndPinch else { return }
        // The camera has stopped sending frames: the hand is not known to be there.
        guard CACurrentMediaTime() * 1000 - lastFrameMs < 500 else { return }
        actions?.aimPointer(headYawDeg: 0, headPitchDeg: 0)
    }

    // MARK: calibration

    /// Why the dots cannot be put up now, in words for the settings window; nil when they can.
    static func calibrationBlocker(store: SettingsStore, state: AppState) -> String? {
        if !state.handsRunning { return "Start hands first." }
        if state.steady { return "Hands do not aim in Steady mode, so there is nothing to calibrate." }
        if store.s.handAim != .handRay { return "Look and pinch aims with your head and needs no calibration." }
        if state.panels.isEmpty { return "It needs a floating screen to show its dots on." }
        if state.handsSeen == 0 { return "Hold a hand up where the glasses can see it." }
        return nil
    }

    func beginCalibration() {
        guard run == nil, let camera, !camera.facing, Self.calibrationBlocker(store: store, state: state) == nil else { return }
        let index: Int = min(max(state.pointerScreen ?? 0, 0), state.panels.count - 1)
        guard let screen = floatingScreen(index) else {
            prefs.lastResult = "Calibration could not find the floating screen to show its dots on."
            return
        }
        plog("hands: calibration on screen \(index + 1)")
        letGo()
        run = HandCalibrationRun()
        runScreen = index
        prefs.calibrating = true
        let window = HandCalibrationWindow(screen: screen) { [weak self] in
            self?.endCalibration("Calibration stopped.")
        }
        window.show(step: 0)
        runWindow = window
        armCalibrationTimer()
    }

    func resetCalibration() {
        plog("hands: calibration reset")
        prefs.calibration = nil
        prefs.lastResult = nil
    }

    /// A pinch while the dots are up: the ray as the camera has it, against where the dot is.
    private func calibrationPinch(_ ray: HandAngles) {
        guard var current = run, let dot = current.dot, state.panels.indices.contains(runScreen) else { return }
        let target: HandAngles = HandCalibrationRun.target(
            panel: state.panels[runScreen], u: dot.u, v: dot.v, headYawDeg: state.yawDeg, headPitchDeg: state.pitchDeg
        )
        current.record(ray: ray, target: target)
        run = current
        plog(String(format: "hands: dot %d ray %.1f, %.1f wanted %.1f, %.1f", current.step, ray.yawDeg, ray.pitchDeg, target.yawDeg, target.pitchDeg))
        guard current.done else {
            runWindow?.show(step: current.step)
            armCalibrationTimer()
            return
        }
        let result: HandCalibrationRun.Result = current.result()
        let off = String(format: "%.1f", result.rmsDeg)
        plog("hands: calibration \(result.ok ? "kept" : "not kept"), \(off) degrees off, \(result.calibration.numbers.map { String(format: "%.3f", $0) }.joined(separator: " "))")
        if result.ok {
            prefs.calibration = result.calibration
            let day = DateFormatter()
            day.dateFormat = "d MMM yyyy"
            endCalibration("Calibrated on \(day.string(from: Date())): the five dots land within \(off) degrees.")
        } else {
            endCalibration("Not kept: the five pinches were \(off) degrees off the dots. Try again, with your hand over each dot as you pinch.")
        }
    }

    /// Puts the dots away. [line] is how it went, nil to leave the last line as it is.
    private func endCalibration(_ line: String?) {
        guard run != nil || runWindow != nil else { return }
        run = nil
        runTimer?.invalidate()
        runTimer = nil
        runWindow?.close()
        runWindow = nil
        prefs.calibrating = false
        if let line { prefs.lastResult = line }
        // The pinch that ended it is still closed: start afresh so its opening is not taken for anything.
        gestures.reset(waitForOpen: true)
    }

    private func armCalibrationTimer() {
        runTimer?.invalidate()
        let t = Timer(timeInterval: Self.calibrationIdleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCalibration("Calibration stopped: no pinch for 30 seconds.") }
        }
        RunLoop.main.add(t, forMode: .common)
        runTimer = t
    }

    /// The floating screen with this index, as AppKit has it: the one where macOS has the display of that tile.
    private func floatingScreen(_ index: Int) -> NSScreen? {
        guard let tile = state.displayTiles.first(where: { $0.id == index }) else { return nil }
        return NSScreen.screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayBounds(id) == tile.frame
        }
    }

    // MARK: the air trackpad's reach

    /// "Set your reach": the next pinch puts the middle of the air trackpad's box where the hand is.
    func beginReach() {
        guard running, let camera, camera.facing, !prefs.settingReach else { return }
        plog("hands: waiting for a pinch to set the reach")
        letGo()
        prefs.settingReach = true
        reachTimer?.invalidate()
        let t = Timer(timeInterval: Self.calibrationIdleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endReach() }
        }
        RunLoop.main.add(t, forMode: .common)
        reachTimer = t
    }

    func resetReach() {
        plog("hands: reach reset")
        prefs.reachCentre = nil
    }

    /// The pinch that sets the reach: [at] is where the pointer was aimed, which says where the hand was.
    private func reachPinch(_ at: HandAngles, air: Bool) {
        if air {
            let place = HandAirBox.openShares(at)
            let centre: HandPoint = HandAirBox(centre: prefs.airBox.point(u: place.u, v: place.v)).centre
            prefs.reachCentre = centre
            plog(String(format: "hands: reach set, the box's middle at %.2f, %.2f of the picture", centre.x, centre.y))
            // The pointer was where the hand is; the hand is now the screen's middle. Start the smoothing there.
            filter.reset()
        }
        endReach()
    }

    private func endReach() {
        reachTimer?.invalidate()
        reachTimer = nil
        guard prefs.settingReach else { return }
        prefs.settingReach = false
        gestures.reset(waitForOpen: true)
    }

    // MARK: permission

    /// The settings' "Allow camera": macOS asks the first time; after a no, only System Settings can change it.
    static func requestCamera() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                plog("hands: camera \(allowed ? "allowed" : "not allowed")")
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Draws hand tracking's settings and its calibration window to picture files, without showing a window.
@MainActor
enum HandsRender {
    /// hands-settings.png: the settings as cards, at the settings window's content width, with the glasses' camera,
    /// hands running, one hand seen, the camera allowed and Accessibility not yet.
    /// hands-settings-mac-camera.png: the same with glasses that have no camera, so the Mac's own is used: the air
    /// trackpad, with a plain panel where the camera's picture goes.
    /// hands-calibration.png: the calibration window on a 1920 x 1080 floating screen, at the second of its five
    /// dots. Returns the files written.
    static func renderAll(to folder: URL) -> [URL] {
        _ = try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = [URL]()

        let store = SettingsStore(defaults: nil)
        var s: SpaceSettings = store.s
        s.handsOn = true
        store.s = s
        let state = AppState()
        state.glassesName = "XREAL Aura"
        state.glassesFamily = .aura
        state.trackingOn = true
        state.virtualScreens = 2
        state.handsRunning = true
        state.handsSeen = 1
        state.handsStatus = "1 hand"
        state.handsCameraFound = true
        state.cameraAllowed = true
        state.accessibilityAllowed = false
        state.pointerScreen = 0
        state.panels = SpaceLayout.arrange(layout: s.layout, aspects: [16.0 / 9, 16.0 / 9], widthDeg: s.widthDeg, distance: s.distance, curve: s.curve)
        let mac = HandsCameraItem(choice: .mac, name: "FaceTime HD Camera")

        let withGlasses = HandsPrefs(defaults: nil)
        withGlasses.cameras = [mac]
        withGlasses.glassesFound = true
        withGlasses.cameraName = "XREAL Aura Camera"
        withGlasses.calibration = HandCalibration(a: 1.04, b: 0.01, c: -2.1, d: -0.02, e: 0.97, f: 1.4)
        withGlasses.lastResult = "Calibrated on 16 Nov 2026: the five dots land within 0.8 degrees."
        let first: URL = folder.appendingPathComponent("hands-settings.png")
        if write(section(store: store, state: state, prefs: withGlasses), scale: 2, to: first) { written.append(first) }

        let withMac = HandsPrefs(defaults: nil)
        withMac.cameras = [mac]
        withMac.glassesFound = false
        withMac.facing = true
        withMac.fellBack = true
        withMac.cameraName = mac.name
        let third: URL = folder.appendingPathComponent("hands-settings-mac-camera.png")
        if write(section(store: store, state: state, prefs: withMac), scale: 2, to: third) { written.append(third) }

        let dots = HandCalibrationView(step: 1, onCancel: {})
            .frame(width: 1920, height: 1080)
            .environment(\.settingsStatic, true)
            .environment(\.colorScheme, .dark)
        let second: URL = folder.appendingPathComponent("hands-calibration.png")
        if write(dots, scale: 1, to: second) { written.append(second) }
        return written
    }

    private static func section(store: SettingsStore, state: AppState, prefs: HandsPrefs) -> some View {
        // The settings window's content: 880 wide, less the 200 sidebar and 28 either side.
        let width: CGFloat = SettingsWindowController.defaultSize.width - SettingsMetrics.sidebarWidth - 56
        return VStack(alignment: .leading, spacing: 20) {
            HandsSettingsSection(store: store, state: state, actions: SettingsActionsRef(nil), prefs: prefs)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .padding(28)
        .environment(\.settingsStatic, true)
        .environment(\.colorScheme, .dark)
        .background(Color.lookPage)
    }

    private static func write<V: View>(_ view: V, scale: CGFloat, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image: CGImage = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png: Data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
