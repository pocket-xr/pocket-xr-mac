import Foundation

/// A One Euro filter on the orientation the screens are drawn with, ported from Pocket XR's DrawSmoothing.kt (0.5.64).
///
/// On Mike's Flip 7 with his Aura an unfiltered head pose changed yaw direction 10 to 18 times a second while the head
/// was held still, and the windows shook with small movements; this filter on the drawn orientation fixed it.
///
/// Each frame the drawn orientation moves toward the predicted one by a share set from a cutoff of [minCutoffHz] plus
/// [beta] times how far behind it is, in degrees per 60 Hz frame. Still, the tremor is cut at about 1 Hz; in a turn the
/// cutoff opens with the lag, so it stays a few degrees at most. The lag term counts per 60 Hz frame whatever the
/// display's rate, so 120 Hz behaves as 60 Hz does.
///
/// [update] once a frame with the frame's pose; [apply] for another pose of that frame, which takes the same
/// correction. Not thread safe: HeadPose holds its lock for every call.
public final class DrawSmoothing {
    /// The frame rate the filter was tuned at: the lag term is in degrees per frame at this rate.
    public static let referenceHz: Double = 60
    /// A longer gap than this restarts from the head, seconds.
    public static let maxGapS: Double = 0.2
    /// Two updates this close together are the same frame's, seconds (under half a 120 Hz frame).
    public static let sameFrameS: Double = 0.002

    public let minCutoffHz: Double
    public let beta: Double

    /// Off: every pose passes as it is.
    public var enabled: Bool = true

    private var filtered: Quat?
    private var lastTime: Double?
    // The filter as it was before this frame's step, so a second update for the same frame redoes the step.
    private var before: Quat?
    private var beforeTime: Double?
    private var correction: Quat = Quat.identity
    private var hasCorrection: Bool = false

    public init(minCutoffHz: Double = 1.0, beta: Double = 0.04) {
        self.minCutoffHz = minCutoffHz
        self.beta = beta
    }

    /// The orientation to draw for the frame's pose [q] at [now] seconds.
    public func update(_ q: Quat, _ now: Double) -> Quat {
        if !enabled {
            free()
            return q
        }
        var sameFrame: Bool = false
        if let last = lastTime {
            let gap: Double = now - last
            sameFrame = gap >= 0 && gap <= DrawSmoothing.sameFrameS
        }
        if sameFrame {
            filtered = before
            lastTime = beforeTime
        } else {
            before = filtered
            beforeTime = lastTime
        }
        let previous: Quat? = filtered
        var dt: Double = 0
        if let last = lastTime { dt = now - last }
        lastTime = now
        // The first frame, or a stall (a pause, a reconnect): start from the head, not from where it was.
        guard let prev = previous, dt > 0, dt <= DrawSmoothing.maxGapS else {
            filtered = q
            correction = Quat.identity
            hasCorrection = false
            return q
        }
        let lagDeg: Double = HeadMath.angleDeg(prev, q)
        let cutoff: Double = minCutoffHz + beta * lagDeg * DrawSmoothing.referenceHz
        let tau: Double = 1 / (2 * Double.pi * cutoff)
        let alpha: Double = 1 / (1 + tau / dt)
        let f: Quat = HeadMath.slerp(prev, q, alpha)
        filtered = f
        correction = (q.conjugate * f).normalized
        hasCorrection = true
        return f
    }

    /// Another pose of the frame [update] last saw: the same correction.
    public func apply(_ q: Quat) -> Quat {
        if !enabled || !hasCorrection { return q }
        return (q * correction).normalized
    }

    /// Starts again from the head with no blend (a recentre, a reconnect, the switch turned off).
    public func free() {
        filtered = nil
        lastTime = nil
        before = nil
        beforeTime = nil
        correction = Quat.identity
        hasCorrection = false
    }
}
