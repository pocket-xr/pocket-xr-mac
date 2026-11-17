import Foundation

// A game controller as a remote for the Space, and Pocket mode's watch: the parts that are only arithmetic, so they
// can be checked without a controller, a screen or glasses (Checks/ControllerChecks.swift).

/// A controller's buttons by where they sit, not by the letter printed on them (the letters differ by maker).
public struct ControllerButtons: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// The face buttons: bottom, right, left, top.
    public static let south = ControllerButtons(rawValue: 1 << 0)
    public static let east = ControllerButtons(rawValue: 1 << 1)
    public static let west = ControllerButtons(rawValue: 1 << 2)
    public static let north = ControllerButtons(rawValue: 1 << 3)
    /// The bumpers (L1, R1).
    public static let leftBumper = ControllerButtons(rawValue: 1 << 4)
    public static let rightBumper = ControllerButtons(rawValue: 1 << 5)
    /// Menu, Options or +.
    public static let menu = ControllerButtons(rawValue: 1 << 6)
    /// The left stick pressed in.
    public static let leftStick = ControllerButtons(rawValue: 1 << 7)
    public static let up = ControllerButtons(rawValue: 1 << 8)
    public static let down = ControllerButtons(rawValue: 1 << 9)
    public static let left = ControllerButtons(rawValue: 1 << 10)
    public static let right = ControllerButtons(rawValue: 1 << 11)

    public static let dpad: ControllerButtons = [.up, .down, .left, .right]
}

/// Everything read from the controller at one moment. Sticks are -1 to 1 (right and up positive), triggers 0 to 1.
public struct ControllerSnapshot: Equatable, Sendable {
    public var buttons: ControllerButtons
    public var rightX: Double
    public var rightY: Double
    public var leftTrigger: Double
    public var rightTrigger: Double

    public init(buttons: ControllerButtons = [], rightX: Double = 0, rightY: Double = 0, leftTrigger: Double = 0,
                rightTrigger: Double = 0) {
        self.buttons = buttons
        self.rightX = rightX
        self.rightY = rightY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }
}

public enum ControllerLogic {
    /// A stick this close to its middle is at rest (sticks never sit at exactly 0).
    public static let stickDeadZone = 0.18
    public static let triggerDeadZone = 0.04
    /// The Space's speed with the stick right over, degrees a second.
    public static let moveDegPerSecond = 40.0
    /// The screens' change of width with a trigger right down, degrees a second.
    public static let sizeDegPerSecond = 25.0
    /// A held D-pad direction acts again this often, seconds.
    public static let repeatEvery = 0.25
    /// The settings are written at most this often while a trigger is held.
    public static let writesPerSecond = 30.0

    /// A stick with its dead zone taken out: nothing inside it, then growing evenly from 0 at its edge to 1 right
    /// over, in the direction the stick points. The dead zone is round, so a diagonal starts as soon as any other way.
    public static func stick(x: Double, y: Double, deadZone: Double = stickDeadZone) -> (x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let size = (x * x + y * y).squareRoot()
        guard size > deadZone, deadZone < 1 else { return (0, 0) }
        let past = min((size - deadZone) / (1 - deadZone), 1)
        return (x / size * past, y / size * past)
    }

    /// A trigger with its dead zone taken out, 0 to 1.
    public static func trigger(_ value: Double, deadZone: Double = triggerDeadZone) -> Double {
        guard value.isFinite, value > deadZone, deadZone < 1 else { return 0 }
        return min((value - deadZone) / (1 - deadZone), 1)
    }

    /// Does the controller change the Space now?
    public static func active(mode: ControllerMode, leftStickIn: Bool) -> Bool {
        switch mode {
        case .off: return false
        case .held: return leftStickIn
        case .always: return true
        }
    }

    /// The buttons that went down between two readings (buttons act on the press, not on letting go).
    public static func pressed(before: ControllerButtons, now: ControllerButtons) -> ControllerButtons {
        now.subtracting(before)
    }

    /// Is anything held that acts for as long as it is held (the right stick, a trigger, the D-pad)? The 60 Hz timer
    /// runs only while this is so.
    public static func continuous(_ s: ControllerSnapshot) -> Bool {
        let move = stick(x: s.rightX, y: s.rightY)
        if move.x != 0 || move.y != 0 { return true }
        if trigger(s.leftTrigger) > 0 || trigger(s.rightTrigger) > 0 { return true }
        return !s.buttons.isDisjoint(with: .dpad)
    }

    /// How far to move the Space in [dt] seconds, degrees (left and up positive): the stick to the right carries the
    /// screens to the right, which is a negative yaw.
    public static func move(_ s: ControllerSnapshot, dt: Double) -> (yawDeg: Double, pitchDeg: Double) {
        let v = stick(x: s.rightX, y: s.rightY)
        return (-v.x * moveDegPerSecond * dt, v.y * moveDegPerSecond * dt)
    }

    /// How much wider the screens get in [dt] seconds, degrees: the right trigger makes them bigger, the left smaller.
    public static func grow(_ s: ControllerSnapshot, dt: Double) -> Double {
        (trigger(s.rightTrigger) - trigger(s.leftTrigger)) * sizeDegPerSecond * dt
    }

    /// The screen the pointer goes to next (an index into the floating screens, nil the Mac's own screen): forward
    /// through the floating screens and then the Mac's own, round and round. With [includeOwn] false the Mac's own
    /// screen is left out (Pocket mode keeps the pointer off it). Nil with no floating screen.
    public static func nextScreen(current: Int?, floating: Int, forward: Bool, includeOwn: Bool = true) -> Int? {
        guard floating > 0 else { return nil }
        // Places in order: the Mac's own screen first (when it counts), then each floating screen.
        let places = floating + (includeOwn ? 1 : 0)
        let shift = includeOwn ? 1 : 0
        var at = 0
        if let current, current >= 0, current < floating {
            at = current + shift
        } else if !includeOwn {
            // Coming from the Mac's own screen with it left out: forward lands on the first, back on the last.
            return forward ? 0 : floating - 1
        }
        let next = ((at + (forward ? 1 : -1)) % places + places) % places
        if includeOwn { return next == 0 ? nil : next - 1 }
        return next
    }
}

/// A held button that acts at once and then again every so often.
public struct ControllerRepeat: Sendable {
    public let every: Double
    private var nextAt: Double?

    public init(every: Double = ControllerLogic.repeatEvery) {
        self.every = every
    }

    /// Call on every reading with whether the button is held and the time now, seconds. True when it should act.
    public mutating func fires(held: Bool, now: Double) -> Bool {
        guard held else { nextAt = nil; return false }
        guard let due = nextAt else {
            nextAt = now + every
            return true
        }
        guard now >= due else { return false }
        // After a stall it does not fire a burst to catch up.
        nextAt = due + every > now ? due + every : now + every
        return true
    }
}

/// Lets small changes pile up and hands them over at most so many times a second, so a held trigger does not write
/// the settings 60 times a second.
public struct ControllerPacer: Sendable {
    public let interval: Double
    private var pending = 0.0
    private var nextAt = -Double.infinity

    public init(perSecond: Double = ControllerLogic.writesPerSecond) {
        interval = 1 / max(perSecond, 1)
    }

    /// Adds [amount]; returns everything piled up when it is time to write, else nil.
    public mutating func add(_ amount: Double, now: Double) -> Double? {
        pending += amount
        guard now >= nextAt, pending != 0 else { return nil }
        // Slots on an even grid, so timer jitter does not lower the rate; after a pause the grid starts afresh.
        nextAt = nextAt + interval >= now ? nextAt + interval : now + interval
        defer { pending = 0 }
        return pending
    }

    /// What is still piled up when the trigger is let go (nil when nothing is).
    public mutating func flush() -> Double? {
        guard pending != 0 else { return nil }
        defer { pending = 0 }
        return pending
    }
}

/// Pocket mode's watch, asked 30 times a second: keeps the pointer on the floating screens, notices the hold that
/// leaves, and leaves by itself when there is nothing left to look at.
public struct PocketWatch: Equatable, Sendable {
    /// Holding the button on the black screen this long leaves.
    public static let holdSeconds = 1.0
    /// The glasses' display gone this long leaves.
    public static let glassesGoneSeconds = 5.0
    /// "Hold to leave Pocket mode" stays this long after the button is let go.
    public static let hintSeconds = 4.0

    public enum Leave: Equatable, Sendable {
        /// The button was held on the black screen.
        case held
        /// The floating screens went away.
        case noScreens
        /// The glasses' display has been gone too long.
        case noGlasses
    }

    public enum Step: Equatable, Sendable {
        case stay
        /// Put the pointer back on this floating screen.
        case pushBack(Int)
        case leave(Leave)
    }

    /// The floating screen the pointer was last on.
    public private(set) var lastScreen: Int
    private var holdStart: Double?
    private var lastHeldAt: Double?
    private var glassesGoneSince: Double?
    /// The button has been seen up since Pocket mode came on (the click that turned it on must not count as a hold).
    private var armed = false

    public init(lastScreen: Int = 0) {
        self.lastScreen = max(lastScreen, 0)
    }

    /// [buttonDown]: the mouse or trackpad button is down. [pointerOnCover]: the pointer is on a blacked-out screen.
    /// [pointerScreen]: the floating screen the pointer is on, nil when it is on none.
    public mutating func step(now: Double, buttonDown: Bool, pointerOnCover: Bool, pointerScreen: Int?,
                              floatingScreens: Int, glassesPresent: Bool) -> Step {
        guard floatingScreens > 0 else { return .leave(.noScreens) }
        if glassesPresent {
            glassesGoneSince = nil
        } else {
            let since = glassesGoneSince ?? now
            glassesGoneSince = since
            if now - since >= Self.glassesGoneSeconds { return .leave(.noGlasses) }
        }
        if let p = pointerScreen, p >= 0, p < floatingScreens { lastScreen = p }
        lastScreen = min(lastScreen, floatingScreens - 1)

        if !buttonDown { armed = true }
        if buttonDown, pointerOnCover, armed {
            let start = holdStart ?? now
            holdStart = start
            lastHeldAt = now
            return now - start >= Self.holdSeconds ? .leave(.held) : .stay
        }
        holdStart = nil
        // A drag is left alone, so the pointer can be carried onto the Mac's screen and held there.
        if buttonDown { return .stay }
        return pointerScreen == nil ? .pushBack(lastScreen) : .stay
    }

    /// How far the hold has got, 0 to 1 (the ring round the lock).
    public func progress(now: Double) -> Double {
        guard let start = holdStart else { return 0 }
        return min(max((now - start) / Self.holdSeconds, 0), 1)
    }

    /// "Hold to leave Pocket mode" shows from the first press until a little after the button is let go.
    public func hintShown(now: Double) -> Bool {
        guard let last = lastHeldAt else { return false }
        return holdStart != nil || now - last < Self.hintSeconds
    }
}
