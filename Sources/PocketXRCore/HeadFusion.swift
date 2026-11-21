import Foundation

/// The newest fused head sample, for the pose chain (HeadPose): everything read under the fusion's lock at once.
public struct HeadSample: Equatable, Sendable {
    /// The head relative to the recentred forward (x right, y up, z back).
    public var orientation: Quat
    /// The gyro's rate with the learnt bias taken out, in the head's own axes, rad/s.
    public var rate: SIMD3<Double>
    /// When the sample was taken, on the host's clock (ProcessInfo.processInfo.systemUptime), seconds: the glasses'
    /// own time stamp carried over by ImuClock, so a burst of reports is not all stamped with the burst's arrival.
    public var hostTime: Double
    /// How many recentres the fusion has made: a change means the orientation's frame jumped.
    public var recentres: Int

    public init(orientation: Quat, rate: SIMD3<Double>, hostTime: Double, recentres: Int) {
        self.orientation = orientation
        self.rate = rate
        self.hostTime = hostTime
        self.recentres = recentres
    }
}

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
    /// A recentre that follows the head's tilt takes its pitch as straight ahead only past this, degrees (Pocket XR's
    /// FusionSettings.recentreTiltMinDeg).
    public static let recentreTiltMinDeg = 15.0
    /// Looking nearly straight up or down, the forward's heading is noise: the head's right side gives it instead.
    static let nearVerticalDeg = 80.0

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
    // The pitch the last recentre took as straight ahead, radians (0 on the horizon), and whether the recentre that
    // waits was asked for by the user (it decides the pitch again) or is the fusion's own (it keeps the pitch).
    private var refPitch = 0.0
    private var recentreSetsTilt = false
    private var recentreFollowsTilt = false
    private var clock = ImuClock()
    private var newest: HeadSample?
    private var sink: ((HeadSample) -> Void)?
    private var stepCounts = FusionSteps()

    /// Recentres made so far (the first sample's and the one when the bias is first known count too).
    public private(set) var recentres = 0
    /// The pitch the last recentre took as straight ahead, degrees up; 0 on the horizon.
    public var recentrePitchDeg: Double {
        lock.lock(); defer { lock.unlock() }
        return refPitch * 180 / .pi
    }

    public private(set) var count = 0
    public private(set) var biasReady = false
    public private(set) var restBlocks = 0
    public private(set) var lastGyro = SIMD3<Double>(0, 0, 0)

    /// The steps used and dropped so far, for the glasses report.
    public var steps: FusionSteps {
        lock.lock(); defer { lock.unlock() }
        return stepCounts
    }

    public init(axes: Axes) {
        sign = axes.sign
        restMax = axes == .aura ? Self.restMaxAura : Self.restMaxOther
    }

    /// One sample from the glasses, which arrived at [arrived] on the host's clock (seconds, the clock HeadPose's
    /// drawPose is called with).
    public func report(_ s: ImuSample, arrived: Double = ProcessInfo.processInfo.systemUptime) {
        let g = s.gyro * sign
        let a = s.accel * sign
        lock.lock()
        var out: HeadSample?
        var to: ((HeadSample) -> Void)?
        if integrate(s, g, a) {
            let host: Int64 = clock.toHost(deviceNs: Int64(bitPattern: s.timestampNs), arrivedNs: Int64(arrived * 1e9))
            let made = HeadSample(
                orientation: (ref.conjugate * q).normalized, rate: lastGyro, hostTime: Double(host) / 1e9, recentres: recentres
            )
            newest = made
            out = made
            to = sink
        }
        lock.unlock()
        // Outside the lock, so the receiver may call back into the fusion.
        if let made = out, let receiver = to { receiver(made) }
    }

    /// The fusion's step for one sample (the lock is held). True when the orientation moved on with it.
    private func integrate(_ s: ImuSample, _ g: SIMD3<Double>, _ a: SIMD3<Double>) -> Bool {
        count += 1
        guard let last = lastTs else {
            lastTs = s.timestampNs
            firstTs = s.timestampNs
            levelFrom(a)
            return false
        }
        let dt = Double(Int64(bitPattern: s.timestampNs &- last)) / 1e9
        lastTs = s.timestampNs
        guard dt > 0, dt < 0.05 else {
            stepCounts.dropped += 1
            stepCounts.lastDroppedS = dt
            return false
        }
        stepCounts.used += 1
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
            applyRecentre()
            wantRecentre = false
        }
        return true
    }

    /// Makes the head's heading straight ahead (the lock is held). A recentre the user asked for with the head more
    /// than recentreTiltMinDeg up or down takes that pitch as straight ahead too, never the roll (Pocket XR 1.2.13);
    /// the fusion's own recentres keep the pitch the last one took.
    private func applyRecentre() {
        let f = q.rotate(SIMD3(0, 0, -1))
        let headPitch = asin(min(1.0, max(-1.0, f.y)))
        if recentreSetsTilt {
            let past = abs(headPitch) > Self.recentreTiltMinDeg * Double.pi / 180
            refPitch = (recentreFollowsTilt && past) ? headPitch : 0
            recentreSetsTilt = false
        }
        var yaw = q.yaw
        if abs(headPitch) >= Self.nearVerticalDeg * Double.pi / 180 {
            // up x right: where the head faces along the floor.
            let r = q.rotate(SIMD3(1, 0, 0))
            let sideLength = (r.z * r.z + r.x * r.x).squareRoot()
            if sideLength >= 0.2 { yaw = atan2(-r.z, r.x) }
        }
        let turn = Quat.aboutY(yaw - recentreYaw)
        ref = refPitch == 0 ? turn : (turn * Quat.aboutX(refPitch)).normalized
        recentres += 1
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
    /// comes in front of the head. With [followTilt] and the head more than recentreTiltMinDeg up or down, the head's
    /// pitch becomes straight ahead too, so the screens come to where the head looks. Takes effect with the next sample.
    public func recentre(yawDeg: Double = 0, followTilt: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        recentreYaw = yawDeg * .pi / 180
        recentreFollowsTilt = followTilt
        recentreSetsTilt = true
        wantRecentre = true
    }

    /// The newest sample: orientation, rate and host time together. Nil before the second report.
    public func latest() -> HeadSample? {
        lock.lock(); defer { lock.unlock() }
        return newest
    }

    /// Every sample from now on is also handed to [receiver], on the thread that reports (HeadPose's predictor needs
    /// each one, not only the newest). One receiver at a time; nil stops it.
    public func setSampleSink(_ receiver: ((HeadSample) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        sink = receiver
    }

    /// The head's orientation relative to the recentred forward.
    public func view() -> Quat {
        lock.lock(); defer { lock.unlock() }
        return ref.conjugate * q
    }
}
