import Foundation

/// Head scroll, ported from Pocket XR's HeadScroll.kt (1.4.6), off by default.
///
/// Where the screens are held in front (Smooth Follow, where they move with the head), a small turn of the head past a
/// dead zone slides the row of screens that way, like a joystick: turn a little right and the screens on the right
/// come towards the middle. The further past the dead zone, the faster, up to a limit; looking back to the middle stops
/// it. The speed eases in and out so the row never jumps.
///
/// Reading a screen near the middle stays still: the dead zone is wider than a glance across the screen in front.
/// Looking down or up past [maxPitchDeg] does not scroll.
///
/// Angles here are as in Pocket XR: the head's turn from where the screens are held, right positive. Not thread safe:
/// HeadPose holds its lock for every call.
public final class HeadScroll {
    public static let deadZoneDeg: Double = 10
    public static let gainPerS: Double = 3
    public static let maxDegS: Double = 45
    public static let easeS: Double = 0.18
    public static let maxPitchDeg: Double = 30
    /// Smooth Follow's anchor rate while Head scroll is on (a 2 s time constant, not 0.5 s): the screens stay in front
    /// long enough for a small turn to scroll them, then come round to where the head settles.
    public static let followRate: Double = 0.5
    static let maxStepS: Double = 0.1
    static let stopDegS: Double = 0.5

    /// The row's speed now, degrees a second (right positive).
    public private(set) var speedDegS: Double = 0

    public init() {}

    /// The turn to add to the view's yaw for a frame [dtS] seconds long, the head [offsetYawDeg] off (right positive)
    /// and [pitchDeg] up.
    public func step(offsetYawDeg: Double, pitchDeg: Double, dtS: Double) -> Double {
        if !offsetYawDeg.isFinite || !pitchDeg.isFinite || !dtS.isFinite || dtS <= 0 { return 0 }
        let dt: Double = min(dtS, HeadScroll.maxStepS)
        let target: Double = HeadScroll.targetSpeed(offsetYawDeg: offsetYawDeg, pitchDeg: pitchDeg)
        let k: Double = 1 - exp(-dt / HeadScroll.easeS)
        speedDegS += (target - speedDegS) * k
        if abs(speedDegS) < HeadScroll.stopDegS && target == 0 { speedDegS = 0 }
        return speedDegS * dt
    }

    /// The speed wanted with the head [offsetYawDeg] off and [pitchDeg] up, before easing.
    public static func targetSpeed(offsetYawDeg: Double, pitchDeg: Double) -> Double {
        if abs(pitchDeg) > maxPitchDeg { return 0 }
        let past: Double = abs(offsetYawDeg) - deadZoneDeg
        if past <= 0 { return 0 }
        let speed: Double = min(past * gainPerS, maxDegS)
        return offsetYawDeg < 0 ? -speed : speed
    }

    /// Still at once (a recentre, the mode left).
    public func stop() {
        speedDegS = 0
    }

    /// The view's yaw after adding [deltaDeg] to [viewYawDeg], kept between [lowDeg] and [highDeg] (the first and last
    /// screens' middles) so the row stops at its ends. A view already outside them is only kept from going further out.
    public static func clamp(viewYawDeg: Double, deltaDeg: Double, lowDeg: Double, highDeg: Double) -> Double {
        let then: Double = viewYawDeg + deltaDeg
        if deltaDeg > 0 { return then > highDeg ? max(viewYawDeg, highDeg) : then }
        if deltaDeg < 0 { return then < lowDeg ? min(viewYawDeg, lowDeg) : then }
        return viewYawDeg
    }
}
