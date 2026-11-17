import Foundation

// What the hands mean, frame by frame and by the clock, with no camera in it so that the checks can run it:
// which hand has the pointer, and the gestures (aim, press, drag, let go, the launcher, recentre). The behaviour
// and the numbers are the Android app's (core/hands: HandGestureRecognizer, PinchLock), cut down to a first
// version: a pinch is a press, moving is a drag, letting go lets go. There is no scroll gesture.

/// Which of the hands in a frame has the pointer. The first hand seen keeps it until it has been out of the
/// picture for [lostMs] (500 ms); a second hand is never given it while the first is there or only just gone.
/// The detector gives hands no names from frame to frame, so they are told apart by where they were.
public final class HandPrimary {
    public let lostMs: Double
    private var primaryAt: HandPoint?
    private var primarySeenMs = 0.0
    private var otherAt: HandPoint?
    private var otherSeenMs = 0.0

    public init(lostMs: Double = 500) {
        self.lostMs = lostMs
    }

    /// The index, among [hands] (each hand's place in the picture), of the hand that has the pointer in this
    /// frame; nil when that hand is not in it.
    public func choose(_ hands: [HandPoint], timeMs: Double) -> Int? {
        if primaryAt != nil, timeMs - primarySeenMs >= lostMs { primaryAt = nil }
        if otherAt != nil, timeMs - otherSeenMs >= lostMs { otherAt = nil }
        guard !hands.isEmpty else { return nil }
        guard let was = primaryAt else {
            // Nobody has the pointer: the first hand listed takes it. When the other hand was already being
            // followed and is the only one here, that is the hand that takes it.
            primaryAt = hands[0]
            primarySeenMs = timeMs
            otherAt = hands.count > 1 ? hands[1] : nil
            otherSeenMs = timeMs
            return 0
        }
        if hands.count == 1 {
            // One hand: the pointer's, unless it is plainly the other hand where that one was.
            if let other = otherAt, Self.gap(hands[0], other) < Self.gap(hands[0], was) {
                otherAt = hands[0]
                otherSeenMs = timeMs
                return nil
            }
            primaryAt = hands[0]
            primarySeenMs = timeMs
            return 0
        }
        var best = 0
        for i in hands.indices where Self.gap(hands[i], was) < Self.gap(hands[best], was) { best = i }
        primaryAt = hands[best]
        primarySeenMs = timeMs
        otherAt = hands[best == 0 ? 1 : 0]
        otherSeenMs = timeMs
        return best
    }

    public func reset() {
        primaryAt = nil
        otherAt = nil
    }

    private static func gap(_ a: HandPoint, _ b: HandPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// One frame of the hand that has the pointer.
public struct HandInput: Equatable, Sendable {
    /// Thumb tip to index tip over the hand's size (HandPoints.pinchRatio).
    public var ratio: Double
    /// The palm is turned to the camera (HandPalm.facesCamera).
    public var palmFacing: Bool
    /// Where the pointer would be aimed now.
    public var aim: HandAngles
    /// What a drag is measured on: the aim itself when the hand aims, the head's turn when the head does.
    public var motion: HandAngles

    public init(ratio: Double, palmFacing: Bool, aim: HandAngles, motion: HandAngles) {
        self.ratio = ratio
        self.palmFacing = palmFacing
        self.aim = aim
        self.motion = motion
    }
}

/// What a frame leads to, in the order to do it.
public enum HandEvent: Equatable, Sendable {
    /// Aim the pointer here.
    case aim(HandAngles)
    /// Press the button; the pointer was aimed at this just before.
    case press(HandAngles)
    /// Let the button go.
    case release
    /// A short pinch with the palm turned to the camera.
    case toggleLauncher
    /// That pinch held.
    case recentre
    /// The hand has been gone long enough to start afresh (after a `release` if it was pressing).
    case handLost
}

/// The numbers the gestures run on. Where they come from on Android is noted on each.
public struct HandGestureSettings: Equatable, Sendable {
    /// Pinch thresholds (PinchDetector, 0.2.1): start below 0.25 for 2 frames or below 0.15 in 1, end above 0.42.
    public var enterRatio = 0.25
    public var exitRatio = 0.42
    public var fastEnterRatio = 0.15
    /// The palm must have faced the camera this long before a pinch counts as a palm pinch (PALM_MENU_MS).
    public var palmMs = 200.0
    /// A palm pinch held this long recentres; let go sooner and it toggles the launcher.
    public var recentreHoldMs = 650.0
    /// The aim locks when the fingers start to close: the ratio is below 0.45 and fell 0.08 within 100 ms
    /// (PinchLockSettings onsetRatio, onsetDrop, closingWindowMs).
    public var onsetRatio = 0.45
    public var onsetDrop = 0.08
    public var closingWindowMs = 100.0
    /// The lock is put where the pointer was 66 ms before, two frames at 30 a second, about when the fingers began
    /// to move (selectBackMs), but never more than 1.6 degrees from where it is (selectCapPx 50 at 31 px a degree).
    public var selectBackMs = 66.0
    public var selectCapDeg = 1.6
    /// A lock that never became a pinch lets go when the fingers reopen: above 0.52, or 0.1 above their tightest
    /// (abortRatio, reopenRise); or after 900 ms (strengthLockTimeoutMs); or, once it has held 250 ms, when the
    /// hand has moved 2.5 degrees on, since a hand moving half closed is aiming and not pinching
    /// (strengthLockMoveDeg, strengthLockMoveAfterMs, 0.5.54).
    public var abortRatio = 0.52
    public var reopenRise = 0.1
    public var lockTimeoutMs = 900.0
    public var lockMoveDeg = 2.5
    public var lockMoveAfterMs = 250.0
    /// While pinched the pointer does not move until the hand has gone 2 degrees from where it pressed and the
    /// pinch has lasted 250 ms, or 6 degrees at once: then it is a drag (dragStartDeg 0.5.11, dragMinMs, dragFarDeg).
    public var dragStartDeg = 2.0
    public var dragMinMs = 250.0
    public var dragFarDeg = 6.0
    /// After a lock or a drag the pointer glides back onto the hand over about this long, not in a jump (glideMs).
    public var glideMs = 90.0
    /// A hand gone this long is lost: a press is let go and everything starts afresh (the brief's 500 ms; Android's
    /// lostAfterMs is 450). Anything shorter is a dropped frame and is held through.
    public var lostMs = 500.0

    public init() {}
}

/// The gestures of the hand that has the pointer. Feed it every frame, with the hand or with nil when the hand is
/// not in the frame, and do what it returns.
public final class HandGestures {
    public enum Phase: Equatable, Sendable {
        /// Aiming.
        case idle
        /// The fingers are closing: the pointer is held still for the click that may come.
        case locked
        /// Pinched, the pointer still held where it was locked.
        case pressed
        /// Pinched and moved: the pointer follows the hand with the button down.
        case dragging
        /// Pinched with the palm turned to the camera: the launcher or recentre, never a click.
        case palmPinch
    }

    public let settings: HandGestureSettings
    public private(set) var phase = Phase.idle
    private let pinch: HandPinchDetector
    /// The last 300 ms: when, how closed, and where the pointer was shown.
    private var history = [(t: Double, ratio: Double, shown: HandAngles)]()
    private var lastSeenMs: Double?
    private var palmSinceMs: Double?
    private var lockPoint = HandAngles.zero
    private var lockMotion = HandAngles.zero
    private var lockSinceMs = 0.0
    private var lockMin = 0.0
    private var pressSinceMs = 0.0
    private var pressMotion = HandAngles.zero
    private var palmFired = false
    /// Added to the aim: what keeps a drag from jumping when it starts, and what then glides away.
    private var offset = HandAngles.zero
    /// After a reset that asked for it: fingers that are closed count as open until they have been seen open, so a
    /// pinch already under way (one that ended a calibration, say) is not taken for a new click.
    private var waitingForOpen = false

    public init(settings: HandGestureSettings = HandGestureSettings()) {
        self.settings = settings
        pinch = HandPinchDetector(enterRatio: settings.enterRatio, exitRatio: settings.exitRatio, fastEnterRatio: settings.fastEnterRatio)
    }

    /// True while the pointer is being held still (a lock, a press that is not yet a drag, a palm pinch).
    public var holdsPointer: Bool { phase == .locked || phase == .pressed || phase == .palmPinch }

    /// The palm has faced the camera long enough that a pinch now would be a palm pinch.
    public func palmReady(timeMs: Double) -> Bool {
        guard let since = palmSinceMs else { return false }
        return timeMs - since >= settings.palmMs
    }

    public func update(_ given: HandInput?, timeMs t: Double) -> [HandEvent] {
        guard var input = given else { return gone(t) }
        let s = settings
        if waitingForOpen {
            if input.ratio > s.exitRatio { waitingForOpen = false } else { input.ratio = 1 }
        }
        let dt: Double = lastSeenMs.map { max(t - $0, 0) } ?? 0
        lastSeenMs = t
        if input.palmFacing {
            if palmSinceMs == nil { palmSinceMs = t }
        } else {
            palmSinceMs = nil
        }
        let recentMax: Double = history.filter { $0.t >= t - s.closingWindowMs }.map { $0.ratio }.max() ?? input.ratio
        let wasPalmReady = palmReady(timeMs: t)
        let pinched = pinch.update(input.ratio)
        var events = [HandEvent]()
        var shown = input.aim + offset

        switch phase {
        case .idle, .locked:
            if pinched {
                if wasPalmReady {
                    phase = .palmPinch
                    palmFired = false
                    pressSinceMs = t
                    shown = history.last?.shown ?? shown
                } else {
                    if phase != .locked { lockPoint = selectPoint(t, shown: shown) }
                    phase = .pressed
                    pressSinceMs = t
                    pressMotion = input.motion
                    shown = lockPoint
                    events.append(.aim(lockPoint))
                    events.append(.press(lockPoint))
                }
            } else if phase == .locked {
                lockMin = min(lockMin, input.ratio)
                let held = t - lockSinceMs
                let reopened = input.ratio > s.abortRatio || input.ratio >= lockMin + s.reopenRise
                let movedOn = held >= s.lockMoveAfterMs && input.motion.distance(to: lockMotion) > s.lockMoveDeg
                if reopened || movedOn || held > s.lockTimeoutMs {
                    // Let go without a jump: the pointer starts from the locked spot and glides onto the hand.
                    phase = .idle
                    offset = lockPoint - input.aim
                }
                shown = lockPoint
            } else if input.ratio < s.onsetRatio && recentMax - input.ratio >= s.onsetDrop {
                lockPoint = selectPoint(t, shown: shown)
                lockMotion = input.motion
                lockSinceMs = t
                lockMin = input.ratio
                phase = .locked
                shown = lockPoint
                events.append(.aim(lockPoint))
            } else {
                offset = offset.scaled(s.glideMs <= 0 ? 0 : exp(-dt / s.glideMs))
                shown = input.aim + offset
                events.append(.aim(shown))
            }

        case .pressed:
            if !pinched {
                phase = .idle
                offset = lockPoint - input.aim
                shown = lockPoint
                events.append(.release)
            } else {
                let moved = input.motion.distance(to: pressMotion)
                let held = t - pressSinceMs
                if (moved >= s.dragStartDeg && held >= s.dragMinMs) || moved >= s.dragFarDeg {
                    // The drag starts from the locked spot: the pointer does not jump to the hand.
                    phase = .dragging
                    offset = lockPoint - input.aim
                    events.append(.aim(lockPoint))
                }
                shown = lockPoint
            }

        case .dragging:
            shown = input.aim + offset
            events.append(.aim(shown))
            if !pinched {
                phase = .idle
                events.append(.release)
            }

        case .palmPinch:
            shown = history.last?.shown ?? shown
            if !pinched {
                if !palmFired { events.append(.toggleLauncher) }
                phase = .idle
                offset = shown - input.aim
            } else if !palmFired && t - pressSinceMs >= s.recentreHoldMs {
                palmFired = true
                events.append(.recentre)
            }
        }

        history.append((t: t, ratio: input.ratio, shown: shown))
        history.removeAll { $0.t < t - 300 }
        return events
    }

    /// Where the pointer was [selectBackMs] ago, or where it is now when that is further off than the cap.
    private func selectPoint(_ t: Double, shown: HandAngles) -> HandAngles {
        let back = t - settings.selectBackMs
        guard let sample = history.last(where: { $0.t <= back }) ?? history.first else { return shown }
        return sample.shown.distance(to: shown) <= settings.selectCapDeg ? sample.shown : shown
    }

    /// A frame without the hand.
    private func gone(_ t: Double) -> [HandEvent] {
        guard let seen = lastSeenMs, t - seen >= settings.lostMs else { return [] }
        var events = [HandEvent]()
        if phase == .pressed || phase == .dragging { events.append(.release) }
        reset()
        events.append(.handLost)
        return events
    }

    /// Starts afresh. A press that is down is NOT let go here: whoever resets while pressed lets it go.
    /// With [waitForOpen], fingers that are closed now do nothing until they have opened.
    public func reset(waitForOpen: Bool = false) {
        waitingForOpen = waitForOpen
        phase = .idle
        pinch.reset()
        history.removeAll()
        lastSeenMs = nil
        palmSinceMs = nil
        palmFired = false
        offset = .zero
    }
}
