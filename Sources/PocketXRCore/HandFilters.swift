import Foundation

// Hand tracking's filters: the One Euro filter that steadies the aim, and the pinch detector with its two
// thresholds. Ported in idea and in numbers from the Android app (core/hands: OneEuroFilter, RayAimFilter,
// PinchDetector).

/// The One Euro filter (Casiez, Roussel and Vogel, CHI 2012): a low pass filter whose cut off rises with speed, so
/// a still hand gives a steady pointer and a fast hand has little lag. [speedFloor] (value units a second) is taken
/// off the speed before [beta] opens the cut off, so that the points' own jitter does not open it for a still hand
/// (Android 0.5.4).
public final class HandOneEuro {
    public let minCutoffHz: Double
    public let beta: Double
    public let derivativeCutoffHz: Double
    public let speedFloor: Double
    private var value = 0.0
    private var derivative = 0.0
    private var lastMs = 0.0
    private var primed = false

    /// The defaults are the Android hand ray's, in degrees (RayFilterSettings, 0.5.45): 1.2 Hz at rest, opening by
    /// 1.5 Hz for each degree a second above 7, with a 2 Hz filter on the speed.
    public init(minCutoffHz: Double = 1.2, beta: Double = 1.5, derivativeCutoffHz: Double = 2.0, speedFloor: Double = 7) {
        self.minCutoffHz = max(minCutoffHz, 1e-3)
        self.beta = max(beta, 0)
        self.derivativeCutoffHz = max(derivativeCutoffHz, 1e-3)
        self.speedFloor = max(speedFloor, 0)
    }

    /// Feeds one value seen at [timeMs] and returns the filtered one. A time that does not move forward changes
    /// nothing.
    public func filter(_ x: Double, timeMs: Double) -> Double {
        if !primed {
            primed = true
            lastMs = timeMs
            value = x
            derivative = 0
            return value
        }
        guard timeMs > lastMs else { return value }
        let dt = (timeMs - lastMs) / 1000
        lastMs = timeMs
        let speed = (x - value) / dt
        derivative += Self.alpha(derivativeCutoffHz, dt) * (speed - derivative)
        let cutoff = minCutoffHz + beta * max(abs(derivative) - speedFloor, 0)
        value += Self.alpha(cutoff, dt) * (x - value)
        return value
    }

    public func reset() {
        primed = false
        derivative = 0
    }

    private static func alpha(_ cutoffHz: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoffHz)
        return 1 / (1 + tau / dt)
    }
}

/// The hand ray's smoothing: yaw and pitch each through their own One Euro filter, so a sideways sweep keeps the
/// pitch as steady as a resting hand's (Android: RayAimFilter).
public final class HandRayFilter {
    private let yaw: HandOneEuro
    private let pitch: HandOneEuro

    public init(minCutoffHz: Double = 1.2, beta: Double = 1.5, derivativeCutoffHz: Double = 2.0, speedFloor: Double = 7) {
        yaw = HandOneEuro(minCutoffHz: minCutoffHz, beta: beta, derivativeCutoffHz: derivativeCutoffHz, speedFloor: speedFloor)
        pitch = HandOneEuro(minCutoffHz: minCutoffHz, beta: beta, derivativeCutoffHz: derivativeCutoffHz, speedFloor: speedFloor)
    }

    public func filter(_ ray: HandAngles, timeMs: Double) -> HandAngles {
        HandAngles(yawDeg: yaw.filter(ray.yawDeg, timeMs: timeMs), pitchDeg: pitch.filter(ray.pitchDeg, timeMs: timeMs))
    }

    public func reset() {
        yaw.reset()
        pitch.reset()
    }
}

/// Pinch on and off with two thresholds (Android: PinchDetector, tuned in 0.2.1). A pinch starts when the thumb to
/// index distance over the hand's size is below [enterRatio] (0.25) for [enterFrames] (2) frames in a row, or below
/// [fastEnterRatio] (0.15, fingers clearly touching) on one frame, which takes a frame off every click. It ends
/// only when the ratio is above [exitRatio] (0.42) for [exitFrames] (2) frames: the gap between the thresholds
/// stops jitter from clicking, a drag does not drop when the fingers loosen a little, and one bad frame never lets go.
public final class HandPinchDetector {
    public let enterRatio: Double
    public let exitRatio: Double
    public let fastEnterRatio: Double
    public let enterFrames: Int
    public let exitFrames: Int
    public private(set) var pinched = false
    private var streak = 0

    public init(enterRatio: Double = 0.25, exitRatio: Double = 0.42, fastEnterRatio: Double = 0.15,
                enterFrames: Int = 2, exitFrames: Int = 2) {
        self.enterRatio = enterRatio
        self.exitRatio = max(exitRatio, enterRatio)
        self.fastEnterRatio = min(fastEnterRatio, enterRatio)
        self.enterFrames = max(enterFrames, 1)
        self.exitFrames = max(exitFrames, 1)
    }

    /// Feeds one frame's ratio and returns whether the hand is pinching after it.
    @discardableResult
    public func update(_ ratio: Double) -> Bool {
        if !pinched && ratio < fastEnterRatio {
            pinched = true
            streak = 0
            return true
        }
        let crossing: Bool = pinched ? ratio > exitRatio : ratio < enterRatio
        streak = crossing ? streak + 1 : 0
        if streak >= (pinched ? exitFrames : enterFrames) {
            pinched.toggle()
            streak = 0
        }
        return pinched
    }

    public func reset() {
        pinched = false
        streak = 0
    }
}
