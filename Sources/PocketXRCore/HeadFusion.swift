import Foundation

/// Head orientation from gyro and accelerometer: a small complementary filter, ported as it is from Pocket XR for
/// Steam Deck's fusion.py (tuned there on Mike's Aura, 11 and 12 November 2026).
///
/// Head axes are x right, y up, z back. The Aura's sensor already uses them; the One family is x right, y down, z front
/// (Pocket XR's AxisMap), so its y and z are negated.
public final class HeadFusion: @unchecked Sendable {
    public enum Axes: Sendable {
        case aura, one
        var sign: SIMD3<Double> { self == .aura ? SIMD3(1, 1, 1) : SIMD3(1, -1, -1) }
    }

    static let kp = 1.0 // how hard tilt follows gravity, 1/s
    static let restBlock = 500 // reports, half a second at 1 kHz
    // A worn head turning slowly once passed an older test and was learnt as bias (the windows crept sideways), so the
    // bias is learnt only from two seconds of real stillness: four quiet half seconds in a row, each axis's mean under
    // 1 deg/s (3 on glasses not calibrated on board) and its spread under 0.6 deg/s.
    static let restSd = 0.6 * Double.pi / 180
    static let restMaxAura = 1.0 * Double.pi / 180
    static let restMaxOther = 3.0 * Double.pi / 180
    static let restRun = 4
    static let restGain = 0.5
    static let firstRecentreS = 5.0

    private let lock = NSLock()
    private let sign: SIMD3<Double>
    private let restMax: Double
    private var q = Quat.identity // world from head
    private var ref = Quat.identity // the recentre
    private var lastTs: UInt64?
    private var firstTs: UInt64 = 0
    private var bias = SIMD3<Double>(0, 0, 0)
    private var biasSum = SIMD3<Double>(0, 0, 0)
    private var biasSq = SIMD3<Double>(0, 0, 0)
    private var biasN = 0
    private var restRunMeans = [SIMD3<Double>]()
    private var gMag: Double?
    private var wantRecentre = true
    private var recentreYaw = 0.0

    public private(set) var count = 0
    public private(set) var biasReady = false
    public private(set) var restBlocks = 0
    public private(set) var lastGyro = SIMD3<Double>(0, 0, 0)

    public init(axes: Axes) {
        sign = axes.sign
        restMax = axes == .aura ? Self.restMaxAura : Self.restMaxOther
    }

    /// One sample from the glasses.
    public func report(_ s: ImuSample) {
        let g = s.gyro * sign
        let a = s.accel * sign
        lock.lock(); defer { lock.unlock() }
        count += 1
        guard let last = lastTs else {
            lastTs = s.timestampNs
            firstTs = s.timestampNs
            levelFrom(a)
            return
        }
        let dt = Double(Int64(bitPattern: s.timestampNs &- last)) / 1e9
        lastTs = s.timestampNs
        guard dt > 0, dt < 0.05 else { return }
        let an = (a * a).sum().squareRoot()
        gMag = gMag.map { 0.999 * $0 + 0.001 * an } ?? an
        learnBias(g, s.timestampNs)
        var w = g - bias
        lastGyro = w
        // Tilt: the accelerometer reads the reaction to gravity, "up", in head axes.
        if an > 0, let gm = gMag, abs(an / gm - 1) < 0.1 {
            let upEst = q.conjugate.rotate(SIMD3(0, 1, 0))
            let am = a / an
            let e = SIMD3(
                am.y * upEst.z - am.z * upEst.y,
                am.z * upEst.x - am.x * upEst.z,
                am.x * upEst.y - am.y * upEst.x
            )
            w += Self.kp * e
        }
        let half = 0.5 * dt
        q = (q * Quat(1, w.x * half, w.y * half, w.z * half)).normalized
        if wantRecentre {
            ref = Quat.aboutY(q.yaw - recentreYaw)
            wantRecentre = false
        }
    }

    private func learnBias(_ g: SIMD3<Double>, _ ts: UInt64) {
        biasSum += g
        biasSq += g * g
        biasN += 1
        guard biasN >= Self.restBlock else { return }
        let n = Double(biasN)
        let mean = biasSum / n
        let variance = biasSq / n - mean * mean
        let sd = SIMD3(max(0, variance.x).squareRoot(), max(0, variance.y).squareRoot(), max(0, variance.z).squareRoot())
        biasSum = .zero
        biasSq = .zero
        biasN = 0
        guard sd.max() < Self.restSd, abs(mean.x) < restMax, abs(mean.y) < restMax, abs(mean.z) < restMax else {
            restRunMeans.removeAll()
            return
        }
        restRunMeans.append(mean)
        guard restRunMeans.count >= Self.restRun else { return }
        let runMean = restRunMeans.reduce(SIMD3<Double>.zero, +) / Double(restRunMeans.count)
        restRunMeans.removeAll()
        let gain = biasReady ? Self.restGain : 1.0 // the first two still seconds are taken as they are
        bias += gain * (runMean - bias)
        restBlocks += 1
        if !biasReady {
            biasReady = true
            if Double(ts &- firstTs) / 1e9 < Self.firstRecentreS { wantRecentre = true }
        }
    }

    /// Starts with tilt from gravity, yaw zero.
    private func levelFrom(_ a: SIMD3<Double>) {
        let n = (a * a).sum().squareRoot()
        guard n > 0 else { return }
        let up = a / n
        let c = up.y
        let axis = SIMD3(-up.z, 0, up.x) // up x (0, 1, 0)
        let s = (axis.x * axis.x + axis.z * axis.z).squareRoot()
        if s < 1e-6 {
            q = c > 0 ? .identity : Quat(0, 1, 0, 0)
            return
        }
        let ang = atan2(s, c)
        let k = sin(ang / 2) / s
        q = Quat(cos(ang / 2), axis.x * k, 0, axis.z * k).normalized
    }

    /// The head's heading becomes straight ahead, with the view turned [yawDeg] (left positive), so the panels' middle
    /// comes in front of the head.
    public func recentre(yawDeg: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        recentreYaw = yawDeg * .pi / 180
        wantRecentre = true
    }

    /// The head's orientation relative to the recentred forward.
    public func view() -> Quat {
        lock.lock(); defer { lock.unlock() }
        return ref.conjugate * q
    }
}
