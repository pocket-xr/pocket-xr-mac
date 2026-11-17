import Foundation

// The hand aim's calibration: "point at the dot and pinch" on five dots, then a least squares fit of a correction
// from the angles the camera's ray had to the angles that land on each dot (Android: RayCalibration and
// HandCalibration in HandRay.kt, 0.5.0). It takes up what the pinhole guess gets wrong: where the camera really
// points, how it is rolled and how wide it sees.

/// A correction of ray angles, degrees: yaw' = a yaw + b pitch + c, pitch' = d yaw + e pitch + f.
public struct HandCalibration: Equatable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    public static let identity = HandCalibration(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0)

    /// Gains outside this range, or cross terms above [maxCross], are a bad fit and not a camera (Android:
    /// MIN_GAIN, MAX_GAIN, MAX_CROSS).
    public static let minGain = 0.6
    public static let maxGain = 1.6
    public static let maxCross = 0.4
    /// A fit further off than this over its own dots is not kept (Android: HandCalibration.maxRmsDeg).
    public static let maxRmsDeg = 2.5

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public var isIdentity: Bool { self == Self.identity }

    public func apply(_ ray: HandAngles) -> HandAngles {
        HandAngles(
            yawDeg: a * ray.yawDeg + b * ray.pitchDeg + c,
            pitchDeg: min(max(d * ray.yawDeg + e * ray.pitchDeg + f, -89), 89)
        )
    }

    /// The six numbers, as kept in the Mac's defaults.
    public var numbers: [Double] { [a, b, c, d, e, f] }

    /// From six finite numbers, else nil.
    public init?(numbers n: [Double]) {
        guard n.count == 6, n.allSatisfy({ $0.isFinite }) else { return nil }
        self.init(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5])
    }

    /// The least squares correction from the [measured] ray angles to the [wanted] ones. With three or more pairs
    /// a full fit, kept only when its gains and cross terms are sensible; otherwise, or with one or two pairs,
    /// the mean offset alone. With none, no correction.
    public static func fit(measured: [HandAngles], wanted: [HandAngles]) -> HandCalibration {
        let n = min(measured.count, wanted.count)
        guard n > 0 else { return identity }
        var offset = identity
        var sumYaw = 0.0
        var sumPitch = 0.0
        for i in 0..<n {
            sumYaw += wanted[i].yawDeg - measured[i].yawDeg
            sumPitch += wanted[i].pitchDeg - measured[i].pitchDeg
        }
        offset.c = sumYaw / Double(n)
        offset.f = sumPitch / Double(n)
        guard n >= 3 else { return offset }
        let rows: [[Double]] = (0..<n).map { [measured[$0].yawDeg, measured[$0].pitchDeg, 1] }
        guard let yaw = solve(rows, (0..<n).map { wanted[$0].yawDeg }),
              let pitch = solve(rows, (0..<n).map { wanted[$0].pitchDeg }) else { return offset }
        let full = HandCalibration(a: yaw[0], b: yaw[1], c: yaw[2], d: pitch[0], e: pitch[1], f: pitch[2])
        let gains = minGain...maxGain
        let sane = gains.contains(full.a) && gains.contains(full.e) && abs(full.b) <= maxCross && abs(full.d) <= maxCross
        return sane ? full : offset
    }

    /// The root mean square angle, degrees, between this correction applied to [measured] and [wanted].
    public func rmsDeg(measured: [HandAngles], wanted: [HandAngles]) -> Double {
        let n = min(measured.count, wanted.count)
        guard n > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<n {
            let d = apply(measured[i]).distance(to: wanted[i])
            sum += d * d
        }
        return (sum / Double(n)).squareRoot()
    }

    /// Least squares x for rows * x = y with three unknowns (the normal equations, solved by elimination with
    /// pivoting), or nil when the rows do not pin all three down (dots in a line).
    static func solve(_ rows: [[Double]], _ y: [Double]) -> [Double]? {
        var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
        for (k, r) in rows.enumerated() {
            for i in 0..<3 {
                for j in 0..<3 { m[i][j] += r[i] * r[j] }
                m[i][3] += r[i] * y[k]
            }
        }
        for col in 0..<3 {
            var pivot = col
            for row in col..<3 where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            if abs(m[pivot][col]) < 1e-9 { return nil }
            m.swapAt(col, pivot)
            for row in 0..<3 where row != col {
                let k = m[row][col] / m[col][col]
                for j in col..<4 { m[row][j] -= k * m[col][j] }
            }
        }
        return (0..<3).map { m[$0][3] / m[$0][$0] }
    }
}

/// One run of the calibration: the dots in order, the pairs gathered so far, and the result after the last.
public struct HandCalibrationRun: Sendable {
    /// Where the dots are on the screen, as shares of its width and height from the top left: the middle, then the
    /// four corners 20 % in from the edges.
    public static let dots: [(u: Double, v: Double)] = [(0.5, 0.5), (0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8)]

    public private(set) var measured = [HandAngles]()
    public private(set) var wanted = [HandAngles]()

    public init() {}

    /// The dot being asked for now (0 is the first), equal to `dots.count` when all are done.
    public var step: Int { measured.count }
    public var done: Bool { measured.count >= Self.dots.count }
    public var dot: (u: Double, v: Double)? { done ? nil : Self.dots[measured.count] }

    /// The angles, in the head's own frame, that land on the point [u], [v] of a screen placed at [panel] in the
    /// Space, with the head turned [headYawDeg], [headPitchDeg] from the Space's forward. Angles are added and
    /// taken away as numbers, which is right to a fraction of a degree while the head is near level.
    public static func target(panel: PanelPlacement, u: Double, v: Double, headYawDeg: Double, headPitchDeg: Double) -> HandAngles {
        HandAngles(
            yawDeg: panel.yawDeg + (0.5 - u) * panel.widthDeg - headYawDeg,
            pitchDeg: panel.pitchDeg + (0.5 - v) * panel.heightDeg - headPitchDeg
        )
    }

    /// A pinch on the current dot: [ray] is the hand's ray then (uncorrected), [target] where the dot is.
    public mutating func record(ray: HandAngles, target: HandAngles) {
        guard !done else { return }
        measured.append(ray)
        wanted.append(target)
    }

    public struct Result: Equatable, Sendable {
        public let calibration: HandCalibration
        public let rmsDeg: Double
        /// Good enough to keep.
        public let ok: Bool
    }

    public func result() -> Result {
        let fit = HandCalibration.fit(measured: measured, wanted: wanted)
        let rms = fit.rmsDeg(measured: measured, wanted: wanted)
        return Result(calibration: fit, rmsDeg: rms, ok: !measured.isEmpty && rms <= HandCalibration.maxRmsDeg)
    }
}
