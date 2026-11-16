import Foundation

/// The tour's steps, one idea each, in the order shown (the Android app's Tour.kt, for a Mac: screens that are real
/// displays, the Mac's pointer, a menu bar app).
public enum TourStep: Int, CaseIterable, Sendable {
    case welcome, setup, screens, look, arrange, depth, menu, done

    /// As shown and spoken: 1 to 8.
    public var number: Int { rawValue + 1 }

    /// A short name for file names (the tour's pictures rendered to files).
    public var slug: String {
        switch self {
        case .welcome: return "welcome"
        case .setup: return "setup"
        case .screens: return "screens"
        case .look: return "look"
        case .arrange: return "arrange"
        case .depth: return "depth"
        case .menu: return "menu"
        case .done: return "done"
        }
    }
}

/// The tour new users see and can reopen whenever they want: its steps, when it opens by itself, what is still to do
/// at the end, what is said for the glasses plugged in, and the beats of its pictures (so the words can follow the
/// picture). The window only draws what this returns.
public enum Tour {
    public static let steps: [TourStep] = TourStep.allCases
    public static var count: Int { steps.count }

    /// The step [by] steps on from [from], kept inside the tour.
    public static func move(_ from: TourStep, by: Int) -> TourStep {
        let i = min(max(from.rawValue + by, 0), steps.count - 1)
        return steps[i]
    }

    public static func isFirst(_ step: TourStep) -> Bool { step == steps.first }
    public static func isLast(_ step: TourStep) -> Bool { step == steps.last }

    // ---- when it opens ----

    /// The tour opens by itself only until it has been seen once. Closing or skipping it counts as seen.
    public static func opensByItself(tourSeen: Bool) -> Bool { !tourSeen }

    // ---- what is still to do at the end ----

    public enum Remaining: Equatable, Sendable {
        /// macOS has not been told Pocket XR may capture its own screens.
        case screenRecording
        case plugInGlasses
        /// Glasses connected and Screen Recording allowed, but no screen is showing a picture on them yet.
        case screensNotShowing
    }

    /// What is still open, in the order to do it. Glasses that are connected with nothing showing on them are not
    /// ready, so the last step never says "look up" at an empty view. Opening at login is optional and never listed.
    public static func remaining(glassesConnected: Bool, screenRecordingAllowed: Bool, capturing: Int) -> [Remaining] {
        var list: [Remaining] = []
        if !screenRecordingAllowed { list.append(.screenRecording) }
        if !glassesConnected {
            list.append(.plugInGlasses)
        } else if screenRecordingAllowed && capturing <= 0 {
            list.append(.screensNotShowing)
        }
        return list
    }

    public static func ready(glassesConnected: Bool, screenRecordingAllowed: Bool, capturing: Int) -> Bool {
        remaining(glassesConnected: glassesConnected, screenRecordingAllowed: screenRecordingAllowed, capturing: capturing).isEmpty
    }

    // ---- what is known for these glasses on a Mac ----

    public enum Support: Equatable, Sendable {
        /// Run on a Mac by the project: the Aura.
        case tested
        /// The One family: the same head tracking as the Aura, not tried on a Mac.
        case sameTrackingUntested
        /// The Air family and VITURE: screens show; head tracking is an experimental switch, untested on a Mac.
        case experimentalTracking
        /// Anything else: screens, without head tracking.
        case screensOnly
    }

    /// What can be said for [family], or nil with no glasses plugged in.
    public static func support(_ family: Glasses.Family?) -> Support? {
        guard let family else { return nil }
        switch family {
        case .aura: return .tested
        case .one: return .sameTrackingUntested
        case .air, .viture: return .experimentalTracking
        case .other: return .screensOnly
        }
    }

    // ---- the pictures' beats ----

    public static let screensLoop = 9.0
    public static let lookLoop = 9.0
    public static let arrangeLoop = 9.0
    public static let depthLoop = 11.0
    /// When the Depth picture turns from 3D to Steady mode's row.
    public static let depthRowAt = 5.6
    public static let menuLoop = 11.0
    /// A looping picture fades in over this long and out over [loopFadeOut] before its end, so a loop never jumps.
    public static let loopFadeIn = 0.4
    public static let loopFadeOut = 0.45

    /// The length of [step]'s loop in seconds, or nil for a picture that plays once and then only drifts.
    public static func loop(_ step: TourStep) -> Double? {
        switch step {
        case .screens: return screensLoop
        case .look: return lookLoop
        case .arrange: return arrangeLoop
        case .depth: return depthLoop
        case .menu: return menuLoop
        case .welcome, .setup, .done: return nil
        }
    }

    /// [t] seconds since a picture came up, as seconds into its loop of [length].
    public static func loopTime(_ t: Double, _ length: Double) -> Double {
        guard length > 0 else { return 0 }
        let r = t.truncatingRemainder(dividingBy: length)
        return r < 0 ? r + length : r
    }

    /// The second that shows each picture's point, for Reduce Motion (the clock stays there) and for stills.
    public static func poster(_ step: TourStep) -> Double {
        switch step {
        case .welcome: return 3.1
        case .setup: return 1.2
        case .screens: return 4.85
        case .look: return 6.0
        case .arrange: return 6.8
        case .depth: return 3.2
        case .menu: return 2.3
        case .done: return 3.0
        }
    }

    /// Three more moments of each looping picture, for stills: before, during and after its main beat.
    public static func stills(_ step: TourStep) -> [Double] {
        switch step {
        case .screens: return [1.2, 2.2, 7.0]
        case .look: return [0.6, 3.2, 4.4]
        case .arrange: return [1.6, 3.8, 5.8]
        case .depth: return [0.7, 2.4, 7.6]
        case .menu: return [1.0, 4.4, 7.0]
        case .welcome, .setup, .done: return []
        }
    }

    /// Which of a step's lines the picture is showing [t] seconds after it came up, so the words light the same
    /// line; -1 for none.
    public static func phase(_ step: TourStep, _ t: Double) -> Int {
        switch step {
        case .screens:
            // The pointer crosses to the floating screen, then a window is carried across.
            let lt = loopTime(t, screensLoop)
            if lt < 2.6 { return 0 }
            return lt < 6.4 ? 1 : -1
        case .arrange:
            // Bigger, nearer, curved, each in turn (only until the user touches a control).
            let lt = loopTime(t, arrangeLoop)
            for (i, at) in arrangeBeats.enumerated() where lt >= at - 0.2 && lt < at + arrangeBeat + 0.6 { return i }
            return -1
        case .depth:
            return loopTime(t, depthLoop) < depthRowAt ? 0 : 1
        case .menu:
            // The menu opens; the highlight reaches "Quit and put the glasses back"; the cable is unplugged.
            let lt = loopTime(t, menuLoop)
            if lt >= 0.3 && lt < 3.4 { return 0 }
            if lt >= 3.4 && lt < 5.2 { return 1 }
            if lt >= 5.5 && lt < 9.5 { return 2 }
            return -1
        case .welcome, .setup, .look, .done:
            return -1
        }
    }

    /// When the Arrange picture's own demonstration starts each change (bigger, nearer, curved), and how long one takes.
    public static let arrangeBeats: [Double] = [0.8, 3.0, 5.2]
    public static let arrangeBeat = 1.2

    /// How far each of the demonstration's changes has got at [t], 0 to 1, not eased.
    public static func arrangeDemo(_ t: Double) -> (bigger: Double, nearer: Double, curved: Double) {
        let lt = loopTime(t, arrangeLoop)
        func k(_ at: Double) -> Double { min(max((lt - at) / arrangeBeat, 0), 1) }
        return (k(arrangeBeats[0]), k(arrangeBeats[1]), k(arrangeBeats[2]))
    }
}
