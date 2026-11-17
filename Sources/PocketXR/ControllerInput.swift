import AppKit
import GameController
import PocketXRCore

// A game controller as a remote for the Space: lean back with the glasses on and move, resize and recentre the
// screens without the keyboard. A controller already works in games on a Mac, so by default it changes the Space
// only while the left stick is held pressed in, and a game on a floating screen keeps the controller to itself.
//
// Not tried with a controller on a Mac yet (16 Nov 2026): the arithmetic is checked (Checks/ControllerChecks.swift),
// the reading of a real controller is not.
//
// It does not rumble and it does not click for you (a click would need Accessibility).

/// A game controller that changes the Space.
@MainActor
final class ControllerInput {
    private let store: SettingsStore
    private let state: AppState
    private weak var actions: AppActions?
    private var observers = [NSObjectProtocol]()
    private var started = false

    /// The controller last heard from, what it read, and its buttons at the reading before (to see presses).
    private weak var pad: GCController?
    private var snapshot = ControllerSnapshot()
    private var before = ControllerButtons()

    /// Runs at 60 Hz only while a stick, a trigger or the D-pad is held.
    private var timer: Timer?
    private var lastTick = 0.0
    private var widthPacer = ControllerPacer()
    private var repeatUp = ControllerRepeat()
    private var repeatDown = ControllerRepeat()
    private var repeatLeft = ControllerRepeat()
    private var repeatRight = ControllerRepeat()
    /// Where a bumper last sent the pointer, and when.
    private var stepped: (to: Int?, at: Double)?

    init(store: SettingsStore, state: AppState, actions: AppActions) {
        self.store = store
        self.state = state
        self.actions = actions
    }

    func start() {
        guard !started else { return }
        started = true
        // Pocket XR lives in the menu bar and is never the app in front: without this it would hear nothing.
        GCController.shouldMonitorBackgroundEvents = true
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let controller = note.object as? GCController
            MainActor.assumeIsolated { self?.connected(controller) }
        })
        observers.append(centre.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let controller = note.object as? GCController
            MainActor.assumeIsolated { self?.disconnected(controller) }
        })
        for controller in GCController.controllers() { attach(controller) }
        publishName()
    }

    // MARK: coming and going

    private func connected(_ controller: GCController?) {
        guard let controller else { return }
        attach(controller)
        publishName()
    }

    private func disconnected(_ controller: GCController?) {
        let name: String = controller?.vendorName ?? "a controller"
        plog("controller: \(name) disconnected")
        controller?.extendedGamepad?.valueChangedHandler = nil
        if controller == nil || controller === pad {
            pad = nil
            snapshot = ControllerSnapshot()
            before = []
            stopTimer()
        }
        publishName()
    }

    private func attach(_ controller: GCController) {
        let name: String = controller.vendorName ?? "Game controller"
        guard let gamepad = controller.extendedGamepad else {
            plog("controller: \(name) connected, but it is not a full gamepad (\(controller.productCategory)); left alone")
            return
        }
        let stickClicks: Bool = gamepad.leftThumbstickButton != nil
        plog("controller: \(name) connected (\(controller.productCategory))\(stickClicks ? "" : ", its left stick does not press in")")
        // The handler is called on the main queue (GCController.handlerQueue's default).
        gamepad.valueChangedHandler = { [weak self, weak controller] _, _ in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.read(controller)
            }
        }
    }

    /// The name the windows show: the controller in use, else the first full gamepad, else nil.
    private func publishName() {
        let all: [GCController] = GCController.controllers().filter { $0.extendedGamepad != nil }
        let chosen: GCController? = all.first { $0 === pad } ?? all.first { $0 === GCController.current } ?? all.first
        let name: String? = chosen.map { $0.vendorName ?? "Game controller" }
        if state.controllerName != name { state.controllerName = name }
    }

    // MARK: reading

    private func look(at gamepad: GCExtendedGamepad) -> ControllerSnapshot {
        var b = ControllerButtons()
        if gamepad.buttonA.isPressed { b.insert(.south) }
        if gamepad.buttonB.isPressed { b.insert(.east) }
        if gamepad.buttonX.isPressed { b.insert(.west) }
        if gamepad.buttonY.isPressed { b.insert(.north) }
        if gamepad.leftShoulder.isPressed { b.insert(.leftBumper) }
        if gamepad.rightShoulder.isPressed { b.insert(.rightBumper) }
        if gamepad.buttonMenu.isPressed { b.insert(.menu) }
        if gamepad.leftThumbstickButton?.isPressed ?? false { b.insert(.leftStick) }
        if gamepad.dpad.up.isPressed { b.insert(.up) }
        if gamepad.dpad.down.isPressed { b.insert(.down) }
        if gamepad.dpad.left.isPressed { b.insert(.left) }
        if gamepad.dpad.right.isPressed { b.insert(.right) }
        return ControllerSnapshot(
            buttons: b,
            rightX: Double(gamepad.rightThumbstick.xAxis.value),
            rightY: Double(gamepad.rightThumbstick.yAxis.value),
            leftTrigger: Double(gamepad.leftTrigger.value),
            rightTrigger: Double(gamepad.rightTrigger.value)
        )
    }

    private var isActive: Bool {
        ControllerLogic.active(mode: store.s.controllerMode, leftStickIn: snapshot.buttons.contains(.leftStick))
    }

    /// Something on the controller changed: act on what was pressed, and run the timer while something is held.
    private func read(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        if pad !== controller {
            pad = controller
            before = []
            publishName()
        }
        snapshot = look(at: gamepad)
        let pressed: ControllerButtons = ControllerLogic.pressed(before: before, now: snapshot.buttons)
        before = snapshot.buttons
        guard isActive else {
            stopTimer()
            return
        }
        if !pressed.isEmpty { act(on: pressed) }
        let now: Double = ProcessInfo.processInfo.systemUptime
        runRepeats(now: now)
        if ControllerLogic.continuous(snapshot) { startTimer(now: now) }
    }

    /// The buttons that act once, on the press.
    private func act(on pressed: ControllerButtons) {
        guard let actions else { return }
        if pressed.contains(.south) { actions.recentre() }
        if pressed.contains(.east) { actions.adjust(.nextLayout) }
        if pressed.contains(.west), state.steadyAvailable, state.linkOpen { actions.setSteady(!state.steady) }
        if pressed.contains(.north) { actions.toggleLauncher() }
        if pressed.contains(.menu) { actions.openControlPanel() }
        if pressed.contains(.rightBumper) { stepPointer(forward: true) }
        if pressed.contains(.leftBumper) { stepPointer(forward: false) }
    }

    /// The pointer to the next or the previous floating screen, round through the Mac's own screen (which is left
    /// out in Pocket mode, where the pointer is kept off it).
    private func stepPointer(forward: Bool) {
        let floating: Int = state.displayTiles.filter { !$0.isOwn }.count
        guard floating > 0 else { return }
        // The app looks where the pointer is four times a second; a second press inside that counts from where the
        // first one sent it.
        let now: Double = ProcessInfo.processInfo.systemUptime
        var current: Int? = state.pointerScreen
        if let last = stepped, now - last.at < 0.5 { current = last.to }
        let next: Int? = ControllerLogic.nextScreen(current: current, floating: floating, forward: forward,
                                                    includeOwn: !state.pocketMode)
        actions?.movePointer(toScreen: next)
        stepped = (to: next, at: now)
    }

    /// The D-pad: at once, then every quarter second while held.
    private func runRepeats(now: Double) {
        let b: ControllerButtons = snapshot.buttons
        let up: Bool = repeatUp.fires(held: b.contains(.up), now: now)
        let down: Bool = repeatDown.fires(held: b.contains(.down), now: now)
        let left: Bool = repeatLeft.fires(held: b.contains(.left), now: now)
        let right: Bool = repeatRight.fires(held: b.contains(.right), now: now)
        guard let actions else { return }
        if up { actions.adjust(.further) }
        if down { actions.adjust(.nearer) }
        if left { actions.adjust(.lessCurve) }
        if right { actions.adjust(.moreCurve) }
    }

    // MARK: while something is held

    private func startTimer(now: Double) {
        guard timer == nil else { return }
        lastTick = now
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        if let rest = widthPacer.flush() { resize(by: rest) }
        // Nothing is held any more as far as the repeats go.
        let now: Double = ProcessInfo.processInfo.systemUptime
        if !isActive {
            _ = repeatUp.fires(held: false, now: now)
            _ = repeatDown.fires(held: false, now: now)
            _ = repeatLeft.fires(held: false, now: now)
            _ = repeatRight.fires(held: false, now: now)
        }
    }

    private func tick() {
        guard let controller = pad, let gamepad = controller.extendedGamepad else {
            stopTimer()
            return
        }
        let now: Double = ProcessInfo.processInfo.systemUptime
        // A stalled main thread must not turn into one large jump.
        let dt: Double = min(max(now - lastTick, 0), 0.05)
        lastTick = now

        // The handler only tells of changes; a stick held steady is read here.
        snapshot = look(at: gamepad)
        let pressed: ControllerButtons = ControllerLogic.pressed(before: before, now: snapshot.buttons)
        before = snapshot.buttons
        guard isActive else {
            stopTimer()
            return
        }
        if !pressed.isEmpty { act(on: pressed) }

        let move = ControllerLogic.move(snapshot, dt: dt)
        if move.yawDeg != 0 || move.pitchDeg != 0 {
            actions?.nudgeSpace(yawDeg: move.yawDeg, pitchDeg: move.pitchDeg)
        }
        let grow: Double = ControllerLogic.grow(snapshot, dt: dt)
        if let amount = widthPacer.add(grow, now: now) { resize(by: amount) }
        runRepeats(now: now)

        if !ControllerLogic.continuous(snapshot) { stopTimer() }
    }

    private func resize(by amount: Double) {
        if state.steady {
            // In Steady mode size is the row's share of the glasses' picture.
            let zoom: ClosedRange<Double> = SpaceSettings.steadyZoomRange
            let next: Double = min(max(store.s.steadyZoom + amount / 40, zoom.lowerBound), zoom.upperBound)
            if next != store.s.steadyZoom { store.s.steadyZoom = next }
            return
        }
        let range: ClosedRange<Double> = SpaceSettings.widthRange
        let width: Double = min(max(store.s.widthDeg + amount, range.lowerBound), range.upperBound)
        if width != store.s.widthDeg { store.s.widthDeg = width }
    }
}
