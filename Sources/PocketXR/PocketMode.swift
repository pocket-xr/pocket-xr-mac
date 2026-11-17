import AppKit
import PocketXRCore
import SwiftUI

// Pocket mode. On the phone it is a black, locked screen for walking about with the phone in a pocket. On a Mac the
// same idea is: everything lives in the glasses, and the Mac's own screen goes dark and out of the way, for privacy on
// a train or a plane and so the pointer never wanders onto a screen nobody is looking at.
//
// The black is only a picture: a window covers the screen. No private API touches the brightness, so an LCD's
// backlight stays on (an OLED or mini-LED screen does go dark where it is black).
//
// Ways out, none of which needs a permission: the shortcut, the menu, the launcher, the switch in the settings (all
// through AppActions.setPocketMode), and from the Mac's own screen holding the mouse or trackpad button on the black
// for a second. The pointer is kept off that screen, but not while the button is down, so it can be dragged there:
// press on a floating screen, move back onto the Mac's screen, keep holding. Nothing listens for keys (a monitor for
// keys in other apps would need Input Monitoring); the button and the pointer's place are only looked at, 30 times a
// second.
//
// It cannot be left stuck: it ends by itself when the floating screens go, and when the glasses' display has been
// gone for 5 seconds.
//
// Not tried with glasses on a Mac yet (16 Nov 2026): the watch's arithmetic is checked (Checks/ControllerChecks.swift).

/// What the black screens show: how far the hold has got, and whether its line is up.
@MainActor
final class PocketCoverModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var hintShown: Bool = false
}

/// Pocket mode: the Mac's own screen black and locked, everything in the glasses.
@MainActor
final class PocketMode {
    private let state: AppState
    private weak var actions: AppActions?
    private let model = PocketCoverModel()
    /// One black window for each of the Mac's own screens (the built-in one, and any other real monitor).
    private var covers = [CGDirectDisplayID: PocketCoverWindow]()
    private var timer: Timer?
    private var watch = PocketWatch()
    private var ticks = 0
    private var glassesPresent = true

    init(state: AppState, actions: AppActions) {
        self.state = state
        self.actions = actions
    }

    private var isOn: Bool { timer != nil || !covers.isEmpty }

    func set(_ on: Bool) {
        if on { enter() } else { leave() }
    }

    // MARK: on and off

    private func enter() {
        guard !isOn else { return }
        // With no floating screen there would be a black Mac and nothing to look at.
        guard state.virtualScreens > 0 else {
            plog("Pocket mode: not turned on, there are no floating screens")
            return
        }
        fitCovers(arriving: true)
        guard !covers.isEmpty else {
            plog("Pocket mode: not turned on, the Mac's own screen was not found")
            return
        }
        watch = PocketWatch(lastScreen: state.pointerScreen ?? 0)
        glassesPresent = NSScreen.glasses != nil
        ticks = 0
        model.progress = 0
        model.hintShown = false
        if !state.pocketMode { state.pocketMode = true }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Always takes every black window away and stops the timer, whatever state it was in.
    private func leave() {
        timer?.invalidate()
        timer = nil
        for cover in covers.values { cover.shut() }
        covers.removeAll()
        model.progress = 0
        model.hintShown = false
        if state.pocketMode { state.pocketMode = false }
    }

    /// Leaves from the inside (the hold, or nothing left to look at): through the app, so it is logged and everything
    /// that shows Pocket mode hears of it, and then directly in case the app did not.
    private func leaveByItself(_ why: String) {
        plog("Pocket mode: \(why)")
        actions?.setPocketMode(false)
        if isOn || state.pocketMode { leave() }
    }

    // MARK: the black windows

    /// The Mac's own screens: every screen that is neither the glasses nor one of Pocket XR's floating screens.
    private func ownScreens() -> [NSScreen] {
        let real: [NSScreen] = NSScreen.screens.filter {
            !Glasses.isGlassesScreenName($0.localizedName) && !$0.localizedName.hasPrefix("Pocket XR")
        }
        if !real.isEmpty { return real }
        // Never the glasses: a fallback that covered them would black out the one thing there is to look at.
        if let own = NSScreen.own, !Glasses.isGlassesScreenName(own.localizedName), !own.localizedName.hasPrefix("Pocket XR") {
            return [own]
        }
        return []
    }

    /// One black window on each of the Mac's own screens, as they are now (screens come, go and change size).
    private func fitCovers(arriving: Bool = false) {
        var wanted = [CGDirectDisplayID: NSScreen]()
        for screen in ownScreens() {
            if let id = screen.displayID { wanted[id] = screen }
        }
        for (id, cover) in covers where wanted[id] == nil {
            cover.shut()
            covers[id] = nil
        }
        for (id, screen) in wanted {
            if let cover = covers[id] {
                if cover.frame != screen.frame { cover.setFrame(screen.frame, display: true) }
                if !cover.isVisible { cover.orderFrontRegardless() }
            } else {
                let cover = PocketCoverWindow(screen: screen, model: model)
                covers[id] = cover
                cover.arrive(faded: arriving)
            }
        }
    }

    // MARK: 30 times a second

    private func tick() {
        guard timer != nil else { return }
        let now: Double = ProcessInfo.processInfo.systemUptime
        ticks += 1
        if ticks % 15 == 0 {
            glassesPresent = NSScreen.glasses != nil
            fitCovers()
        }

        // Where the pointer is, in the display coordinates the tiles use (x right, y down).
        let floating: [DisplayTile] = state.displayTiles.filter { !$0.isOwn }
        let at: CGPoint? = CGEvent(source: nil)?.location
        var onCover = false
        var onScreen: Int?
        if let at {
            onCover = covers.keys.contains { CGDisplayBounds($0).contains(at) }
            onScreen = floating.first { $0.frame.contains(at) }?.id
            // Before the app has published where the floating screens are, only a black screen is known not to be one.
            if floating.isEmpty, !onCover { onScreen = watch.lastScreen }
        } else {
            onScreen = watch.lastScreen
        }
        let buttonDown: Bool = NSEvent.pressedMouseButtons & 1 != 0
        let count: Int = state.virtualScreens > 0 ? max(floating.count, 1) : 0

        let step = watch.step(now: now, buttonDown: buttonDown, pointerOnCover: onCover, pointerScreen: onScreen,
                              floatingScreens: count, glassesPresent: glassesPresent)
        switch step {
        case .stay:
            break
        case .pushBack(let screen):
            actions?.movePointer(toScreen: screen)
        case .leave(let why):
            switch why {
            case .held: leaveByItself("left by holding the button on the Mac's screen")
            case .noScreens: leaveByItself("left by itself, the floating screens are gone")
            case .noGlasses: leaveByItself("left by itself, the glasses' display has been gone for 5 s")
            }
            return
        }

        let progress: Double = watch.progress(now: now)
        if model.progress != progress { model.progress = progress }
        let hint: Bool = watch.hintShown(now: now)
        if model.hintShown != hint { model.hintShown = hint }
    }
}

/// A borderless black window over one of the Mac's own screens, above the menu bar and the Dock, on every Space.
/// It takes clicks (so nothing under it is clicked by mistake) without bringing Pocket XR to the front.
private final class PocketCoverWindow: NSPanel {
    init(screen: NSScreen, model: PocketCoverModel) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // The level the glasses' own window uses: above the menu bar, the Dock and full-screen apps.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: PocketCoverView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Comes up, with a short fade when Pocket mode is turned on (not with Reduce Motion).
    func arrive(faded: Bool) {
        let fade: Bool = faded && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = fade ? 0 : 1
        orderFrontRegardless()
        guard fade else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Look.enter
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(Look.easeEnter.0), Float(Look.easeEnter.1),
                                                           Float(Look.easeEnter.2), Float(Look.easeEnter.3))
            self.animator().alphaValue = 1
        }
    }

    /// Goes at once: leaving must never wait on an animation.
    func shut() {
        ignoresMouseEvents = true
        orderOut(nil)
        contentView = nil
    }
}

/// What a black screen shows.
struct PocketCoverView: View {
    @ObservedObject var model: PocketCoverModel

    var body: some View {
        PocketCoverFace(progress: model.progress, hintShown: model.hintShown)
    }
}

/// Black, and in the middle, very faint, a small lock and "Pocket mode". While the button is held on it a ring fills
/// round the lock and "Hold to leave Pocket mode" is up.
struct PocketCoverFace: View {
    /// How far the hold has got, 0 to 1.
    let progress: Double
    let hintShown: Bool

    private static let ring: CGFloat = 64
    private static let faint: Double = 0.08

    var body: some View {
        let held: Bool = progress > 0
        return ZStack {
            Color.black
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2)
                    .opacity(hintShown ? 1 : 0)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(Color.lookHeld, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(Angle(degrees: -90))
                    .opacity(held ? 1 : 0)
                    .animation(Animation.linear(duration: 1.0 / 30), value: progress)
                Image(systemName: "lock.fill")
                    .font(Font.system(size: 21, weight: .regular))
                    .foregroundColor(Color.white.opacity(held ? 0.64 : Self.faint))
            }
            .frame(width: Self.ring, height: Self.ring)
            VStack(spacing: 6) {
                Text("Pocket mode")
                    .font(Font.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(Self.faint))
                Text("Hold to leave Pocket mode")
                    .font(Font.lookNote)
                    .foregroundColor(Color.white.opacity(0.56))
                    .opacity(hintShown ? 1 : 0)
            }
            .fixedSize()
            // Under the ring, so the lock itself is the screen's exact middle.
            .offset(x: 0, y: Self.ring / 2 + 36)
        }
        .animation(Animation.lookEnter(), value: hintShown)
        .animation(Animation.lookEnter(Look.quick), value: held)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pocket mode"))
        .accessibilityHint(Text("Hold the mouse or trackpad button here for a second to leave"))
    }
}
