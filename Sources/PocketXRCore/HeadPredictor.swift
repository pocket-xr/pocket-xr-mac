import Foundation

// The head pose at the time a frame's light leaves the glasses, ported from Pocket XR's HeadPrediction.kt (ImuClock,
// HeadPredictor, HeadHold). Pocket XR's TremorPredictor, which learns a worn head's tremor, is left out: this is the
// predictor Pocket XR 0.5.19 shipped (smoothed rate and acceleration, the One Euro rate filter, the still head mode),
// with 0.5.30's still blend fitted to its own prediction.

/// Small rotation sums the pose chain shares. Angles in radians unless a name says degrees.
enum HeadMath {
    static let degPerRad: Double = 180.0 / Double.pi

    static func length(_ v: SIMD3<Double>) -> Double {
        return (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        return min(max(x, lo), hi)
    }

    /// 0 to 1 with a soft start and end.
    static func smooth(_ x: Double) -> Double {
        let c: Double = clamp(x, 0, 1)
        return c * c * (3 - 2 * c)
    }

    /// [a] moved [k] of the way to [b].
    static func toward(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ k: Double) -> SIMD3<Double> {
        return a + (b - a) * k
    }

    static func isFinite(_ q: Quat) -> Bool {
        return q.w.isFinite && q.x.isFinite && q.y.isFinite && q.z.isFinite
    }

    /// The shortest way from [a] to [b], [t] of it (0 is [a], 1 is [b]).
    static func slerp(_ a: Quat, _ b: Quat, _ t: Double) -> Quat {
        var d: Double = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
        var bw: Double = b.w
        var bx: Double = b.x
        var by: Double = b.y
        var bz: Double = b.z
        if d < 0 {
            d = -d
            bw = -bw
            bx = -bx
            by = -by
            bz = -bz
        }
        var ka: Double = 1 - t
        var kb: Double = t
        if d < 0.999999 {
            let theta: Double = acos(d)
            let s: Double = sin(theta)
            ka = sin((1 - t) * theta) / s
            kb = sin(t * theta) / s
        }
        return Quat(ka * a.w + kb * bw, ka * a.x + kb * bx, ka * a.y + kb * by, ka * a.z + kb * bz).normalized
    }

    /// [q] turned on by the rate [omega] (the head's own axes, rad/s) for [dt] seconds.
    static func turnedBy(_ q: Quat, _ omega: SIMD3<Double>, _ dt: Double) -> Quat {
        let l: Double = length(omega)
        let angle: Double = l * dt
        if angle < 1e-12 { return q }
        let k: Double = sin(angle / 2) / l
        return (q * Quat(cos(angle / 2), omega.x * k, omega.y * k, omega.z * k)).normalized
    }

    /// The turn from [a] to [b] as a rotation vector (radians, the head's axes); exact for small angles.
    static func turnVector(_ a: Quat, _ b: Quat) -> SIMD3<Double> {
        let d: Quat = a.conjugate * b
        let s: Double = d.w < 0 ? -2 : 2
        return SIMD3<Double>(d.x * s, d.y * s, d.z * s)
    }

    /// The angle between [a] and [b], degrees.
    static func angleDeg(_ a: Quat, _ b: Quat) -> Double {
        let d: Quat = a.conjugate * b
        let v: Double = min(1, (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
        return 2 * asin(v) * degPerRad
    }

    /// Where [q] points: yaw (left positive) and pitch (up positive), degrees.
    static func yawPitchDeg(_ q: Quat) -> (yaw: Double, pitch: Double) {
        let f: SIMD3<Double> = q.rotate(SIMD3<Double>(0, 0, -1))
        let yaw: Double = atan2(-f.x, -f.z) * degPerRad
        let pitch: Double = asin(clamp(f.y, -1, 1)) * degPerRad
        return (yaw, pitch)
    }
}

/// The glasses' sample times on the host's clock (Pocket XR 0.5.10).
///
/// The stream arrives in bursts, so a sample's arrival says little about when it was taken. The glasses' clock runs at
/// a steady rate, so host time = device time + offset, where the offset is the smallest (arrival - device time) seen:
/// the sample that waited least on the way. It may creep up by [driftNsPerSample] a sample (the two clocks' rates
/// differ a little) and starts again when the device clock jumps (a reconnect).
public struct ImuClock: Sendable {
    public var driftNsPerSample: Int64
    public var jumpNs: Int64
    private var offset: Int64?

    public init(driftNsPerSample: Int64 = 100, jumpNs: Int64 = 500_000_000) {
        self.driftNsPerSample = driftNsPerSample
        self.jumpNs = jumpNs
        self.offset = nil
    }

    /// The host time (ns) of a sample stamped [deviceNs] that arrived at [arrivedNs].
    public mutating func toHost(deviceNs: Int64, arrivedNs: Int64) -> Int64 {
        let candidate: Int64 = arrivedNs &- deviceNs
        var next: Int64 = candidate
        if let o = offset {
            let gap: Int64 = candidate &- o
            if gap < -jumpNs || gap > jumpNs {
                next = candidate
            } else if gap < 0 {
                next = candidate
            } else {
                next = o &+ min(driftNsPerSample, gap)
            }
        }
        offset = next
        return deviceNs &+ next
    }

    public mutating func reset() {
        offset = nil
    }
}

/// What the view does when head tracking pauses (Pocket XR 0.5.10): a pause of up to [holdS] keeps the last pose,
/// unpredicted, and the stream carries on from it when it comes back; only after that does the view go head-locked.
public enum HeadHold {
    public static let freshS: Double = 0.1
    public static let holdS: Double = 5.0

    public enum Use: Sendable { case predict, hold, none }

    /// Predict from samples newer than [freshS]; else hold the last pose until [holdS]; else none.
    public static func use(sinceSampleS: Double, hasPose: Bool) -> Use {
        if !hasPose { return .none }
        if sinceSampleS <= freshS { return .predict }
        if sinceSampleS <= holdS { return .hold }
        return .none
    }
}

/// The head pose at a display frame's light time (Pocket XR 0.5.10 to 0.5.30).
///
/// Each fused sample comes with its host time. The rate is smoothed (raw 1 kHz gyro samples carry a few degrees a
/// second of noise, which a 30 ms prediction turns into visible shake) and so is its change, the angular acceleration.
/// [predict] turns the newest orientation on by the rate, plus the acceleration's share, to the target time, never
/// further than [maxAheadMs].
///
/// Not thread safe: HeadPose holds its lock for every call.
public final class HeadPredictor {
    /// The rate filter when the head moves, ms (a 53 Hz low pass).
    public static let rateTauMs: Double = 3
    public static let accelTauMs: Double = 10
    public static let maxAheadMs: Double = 80
    /// Angular acceleration above this (rad/s^2) is noise or a knock, not a head.
    public static let maxAccel: Double = 400
    static let activityMs: Double = 300
    /// The acceleration term counts fully once the head's recent peak rate reaches this (rad/s, about 17 deg/s).
    static let accelFullRate: Double = 0.3

    // The One Euro rate filter (0.5.18): 6 Hz at rest, opening with the head's speed and acceleration to rateTauMs.
    public static let euroMinHz: Double = 6
    public static let euroBetaRate: Double = 40000
    static let euroRateFloor: Double = 0.002
    static let euroBetaAccel: Double = 40
    static let euroAccelFloor: Double = 2

    // The still head mode (0.5.18): under stillEnter rad/s prediction fades over stillRiseMs to stillShare of itself,
    // back in full by stillExit.
    static let stillEnter: Double = 0.0025
    static let stillExit: Double = 0.005
    static let stillShare: Double = 0.05
    static let stillRiseMs: Double = 300
    static let stillFallMs: Double = 20

    // The still blend (0.5.30): the prediction scaled by the share of it that came true. Every sample's prediction
    // blendRefMs ahead is set, once that time has passed, against the turn the gyro then made; the least squares gain
    // over the last blendTauMs (0 to 1) scales the prediction, and a move lets it go to 1 at once.
    public static let blendRefMs: Double = 30
    public static let blendTauMs: Double = 160
    static let blendReleaseLow: Double = 3
    static let blendReleaseHigh: Double = 6
    static let blendSpeedLow: Double = 0.1
    static let blendSpeedHigh: Double = 0.25
    static let blendCap: Int = 256
    static let blendWarmup: Int = 200
    static let turnSpeedMs: Double = 100

    public var stillHead: Bool = true
    public var stillBlend: Bool = true

    /// The newest sample's orientation and host time (seconds); nil before the first.
    public private(set) var orientation: Quat?
    public private(set) var sampleTime: Double = 0

    private var rate = SIMD3<Double>(0, 0, 0)
    private var accel = SIMD3<Double>(0, 0, 0)
    private var activity: Double = 0
    private var fastRate = SIMD3<Double>(0, 0, 0)
    private var fastAccel: Double = 0
    private var stillSlide: Double = 0
    private var stillWanted: Bool = false
    /// The still head mode's weight: 0 moving, 1 still.
    public private(set) var stillWeight: Double = 0
    /// The gyro's peak speed, falling away over 0.1 s, rad/s.
    public private(set) var turnSpeed: Double = 0

    // The still blend's ring of predictions waiting for their turn to finish, and the gyro's integral.
    private var blendT: [Double]
    private var blendP: [SIMD3<Double>]
    private var blendI: [SIMD3<Double>]
    private var blendHead: Int = 0
    private var blendTail: Int = 0
    private var integral = SIMD3<Double>(0, 0, 0)
    private var blendMade: Double = 0
    private var blendPred: Double = 0
    private var blendWeight: Double = 0
    private var blendNow: Double = 0
    private var blendCount: Int = 0
    /// The still blend's fitted gain (0 to 1) and the share of the prediction it gives now.
    public private(set) var blendGain: Double = 1
    public private(set) var blendShare: Double = 1

    public init() {
        blendT = [Double](repeating: 0, count: HeadPredictor.blendCap)
        blendP = [SIMD3<Double>](repeating: SIMD3<Double>(0, 0, 0), count: HeadPredictor.blendCap)
        blendI = [SIMD3<Double>](repeating: SIMD3<Double>(0, 0, 0), count: HeadPredictor.blendCap)
    }

    /// The smoothed rate in the head's axes, rad/s.
    public var angularVelocity: SIMD3<Double> { return rate }

    /// The share of the prediction the still head mode gives now (1 moving, stillShare still).
    public var predictionShare: Double { return 1 - stillWeight * (1 - HeadPredictor.stillShare) }

    /// One fused sample: the orientation [q], the rate [omega] in the head's axes (rad/s), taken at [host] seconds.
    public func add(_ q: Quat, _ omega: SIMD3<Double>, _ host: Double) {
        let hadPose: Bool = orientation != nil
        let dtMs: Double = hadPose ? (host - sampleTime) * 1000 : 0
        let steady: Bool = hadPose && dtMs > 0 && dtMs <= 100
        if !steady {
            let speed: Double = HeadMath.length(omega)
            rate = omega
            accel = SIMD3<Double>(0, 0, 0)
            activity = speed
            fastRate = omega
            fastAccel = 0
            stillSlide = 0
            stillWanted = false
            stillWeight = 0
            turnSpeed = speed
            blendClear()
        } else {
            // The rate through the 3 ms filter and its change, which open the One Euro filter.
            let kf: Double = dtMs / (HeadPredictor.rateTauMs + dtMs)
            let nextFast: SIMD3<Double> = HeadMath.toward(fastRate, omega, kf)
            let fastChange: Double = HeadMath.length(nextFast - fastRate) * (1000 / dtMs)
            fastAccel += (fastChange - fastAccel) * (dtMs / (HeadPredictor.accelTauMs + dtMs))
            fastRate = nextFast

            let k: Double = dtMs / (rateTau() + dtMs)
            let next: SIMD3<Double> = HeadMath.toward(rate, omega, k)
            let change: SIMD3<Double> = (next - rate) * (1000 / dtMs)
            let ka: Double = dtMs / (HeadPredictor.accelTauMs + dtMs)
            accel = HeadMath.toward(accel, change, ka)
            let accelLength: Double = HeadMath.length(accel)
            if accelLength > HeadPredictor.maxAccel { accel = accel * (HeadPredictor.maxAccel / accelLength) }
            rate = next
            activity = max(HeadMath.length(rate), activity * exp(-dtMs / HeadPredictor.activityMs))
            turnSpeed = max(HeadMath.length(omega), turnSpeed * exp(-dtMs / HeadPredictor.turnSpeedMs))
            if stillHead { stillStep(dtMs) } else { stillWeight = 0 }
            if stillBlend { blendStep(omega, host, dtMs) }
        }
        orientation = q
        sampleTime = host
    }

    /// The orientation at [target] (host seconds), or nil before the first sample.
    public func predict(_ target: Double) -> Quat? {
        guard let q = orientation else { return nil }
        let dt: Double = HeadMath.clamp(target - sampleTime, 0, HeadPredictor.maxAheadMs / 1000)
        if dt <= 0 { return q }
        let share: Double = stillHead ? predictionShare : 1
        let blend: Double = stillBlend ? blendShare : 1
        let scale: Double = share * blend
        let whole: SIMD3<Double> = classicStep(dt)
        let step = SIMD3<Double>(whole.x * scale, whole.y * scale, whole.z * scale)
        return HeadMath.turnedBy(q, step, 1)
    }

    public func reset() {
        orientation = nil
        sampleTime = 0
        rate = SIMD3<Double>(0, 0, 0)
        accel = SIMD3<Double>(0, 0, 0)
        activity = 0
        fastRate = SIMD3<Double>(0, 0, 0)
        fastAccel = 0
        stillSlide = 0
        stillWanted = false
        stillWeight = 0
        turnSpeed = 0
        blendClear()
    }

    /// The rate filter's time constant for this step, ms: the One Euro rule.
    private func rateTau() -> Double {
        let overRate: Double = max(0, HeadMath.length(fastRate) - HeadPredictor.euroRateFloor)
        let overAccel: Double = max(0, fastAccel - HeadPredictor.euroAccelFloor)
        let speed: Double = HeadPredictor.euroBetaRate * overRate + HeadPredictor.euroBetaAccel * overAccel
        let openHz: Double = 1000 / (2 * Double.pi * HeadPredictor.rateTauMs)
        let hz: Double = HeadMath.clamp(HeadPredictor.euroMinHz + speed, HeadPredictor.euroMinHz, openHz)
        return 1000 / (2 * Double.pi * hz)
    }

    /// The still head weight. The filtered rate decides with hysteresis whether the head is still; the weight slides
    /// toward that over stillRiseMs (in) or stillFallMs (out), and a move on the 3 ms rate takes it down at once,
    /// smoothly from stillEnter to none left at stillExit.
    private func stillStep(_ dtMs: Double) {
        let slow: Double = HeadMath.length(rate)
        if slow <= HeadPredictor.stillEnter {
            stillWanted = true
        } else if slow >= HeadPredictor.stillExit {
            stillWanted = false
        }
        if stillWanted {
            stillSlide += (1 - stillSlide) * (dtMs / (HeadPredictor.stillRiseMs + dtMs))
        } else {
            stillSlide *= 1 - dtMs / (HeadPredictor.stillFallMs + dtMs)
        }
        let band: Double = HeadPredictor.stillExit - HeadPredictor.stillEnter
        let gate: Double = 1 - HeadMath.smooth((HeadMath.length(fastRate) - HeadPredictor.stillEnter) / band)
        stillWeight = min(stillSlide, gate)
    }

    /// Rate integration with the acceleration's share: angle = w t + a w' t^2 / 2.
    private func classicStep(_ dt: Double) -> SIMD3<Double> {
        let accelShare: Double = HeadMath.clamp(activity / HeadPredictor.accelFullRate, 0, 1)
        return rate * dt + accel * (accelShare * dt * dt / 2)
    }

    private func blendClear() {
        blendHead = 0
        blendTail = 0
        integral = SIMD3<Double>(0, 0, 0)
        blendMade = 0
        blendPred = 0
        blendWeight = 0
        blendNow = 0
        blendCount = 0
        blendGain = 1
        blendShare = 1
    }

    /// One sample of the still blend, after the filters have the sample.
    private func blendStep(_ omega: SIMD3<Double>, _ host: Double, _ dtMs: Double) {
        let cap: Int = HeadPredictor.blendCap
        let refS: Double = HeadPredictor.blendRefMs / 1000
        integral += omega * (dtMs / 1000)
        let k: Double = dtMs / (HeadPredictor.blendTauMs + dtMs)
        while blendTail != blendHead && blendT[blendTail] + refS <= host {
            let p: SIMD3<Double> = blendP[blendTail]
            let turned: SIMD3<Double> = integral - blendI[blendTail]
            let made: Double = turned.x * p.x + turned.y * p.y + turned.z * p.z
            let pp: Double = p.x * p.x + p.y * p.y + p.z * p.z
            blendMade += (made - blendMade) * k
            blendPred += (pp - blendPred) * k
            blendWeight += (1 - blendWeight) * k
            blendCount += 1
            blendTail = (blendTail + 1) % cap
        }
        // Before 0.2 s of finished turns the gain is not trusted: 1.
        if blendCount < HeadPredictor.blendWarmup || blendPred <= 1e-18 {
            blendGain = 1
        } else {
            blendGain = HeadMath.clamp(blendMade / blendPred, 0, 1)
        }
        let now: SIMD3<Double> = classicStep(refS)
        blendT[blendHead] = host
        blendP[blendHead] = now
        blendI[blendHead] = integral
        blendHead = (blendHead + 1) % cap
        if blendHead == blendTail { blendTail = (blendTail + 1) % cap }
        blendNow = now.x * now.x + now.y * now.y + now.z * now.z
        blendShare = blendShareNow()
    }

    /// The fitted gain, let go to 1 by a move (the prediction against its own recent size, or the gyro's peak).
    private func blendShareNow() -> Double {
        let rms: Double = blendWeight > 0 ? (blendPred / blendWeight).squareRoot() : 0
        let z: Double = rms > 0 ? blendNow.squareRoot() / rms : Double.greatestFiniteMagnitude
        let low: Double = HeadPredictor.blendReleaseLow
        let high: Double = HeadPredictor.blendReleaseHigh
        let byPrediction: Double = HeadMath.smooth((z - low) / (high - low))
        let speedBand: Double = HeadPredictor.blendSpeedHigh - HeadPredictor.blendSpeedLow
        let bySpeed: Double = HeadMath.smooth((turnSpeed - HeadPredictor.blendSpeedLow) / speedBand)
        return blendGain + (1 - blendGain) * max(byPrediction, bySpeed)
    }
}
