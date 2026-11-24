import Foundation

/// Taps on the glasses, read from their own motion sensor: two taps recentre, three switch the view. Ported from
/// Pocket XR for Steam Deck 0.7.11 (pocketxr/taps.py) with the same values, asked for by a tester (Pierre Zammit,
/// 23 Nov 2026) so the jobs work with nothing in your hands.
///
/// What a tap looks like, from his XBX A01+ (about 1000 reports a second):
/// - The first version (the Deck's 0.7.5, which the Mac's 0.5.8 ported) wanted a jolt of 0.8 g, back under 0.3 g
///   within 40 ms. His taps on the top of the frame were much softer: 0.33 to 0.51 g away from the 30 ms average, with
///   a quick swing after them lasting 30 to 60 ms. Double taps worked only twice in many tries.
/// - What sets a tap apart is how suddenly it starts: the acceleration jumped 0.23 to 0.42 g within 3 ms. In his four
///   recordings of plain head movement (turning up to 93 degrees a second) no 3 ms jump went over 0.10 g.
///
/// So a jolt starts when the acceleration is `logG` away from its 30 ms average, and ends once it has stayed under it
/// for `settleS` (the swing after a tap is part of the same jolt). It counts as a tap when:
/// - it peaked at `tapG` or more,
/// - it jumped `jerkG` or more within 3 ms somewhere in it (sharp, not a push or a nod),
/// - it lasted no longer than `spikeMaxS` (his firm taps, 0.8 to 5 g, lasted 61 to 101 ms with their swing),
/// - `quietBeforeS` passed since the last jolt ended,
/// - the head turned slower than `turnMax` on average over the 150 ms before it.
///
/// Taps `tapGapMinS` to `tapGapMaxS` apart make a run, about 1.5 to 5 taps a second (his were about 320 ms apart;
/// putting the glasses on gave two sharp jolts 134 ms apart, too close for a run). Once `runEndS` passes without
/// another, a run of two or three is reported. One tap, or four and more, does nothing.
///
/// Tap sensitivity (25 to 300%) divides the jolt and the jump a tap needs: above 100 softer taps count, below only
/// firmer ones. 100 keeps the values above, which the tester liked on the Deck (24 Nov 2026).
///
/// Every jolt goes to the log ([takeLog]) with its peak, how long it lasted, the quiet before it, the head's turn, the
/// gap to the last tap and whether it counted (and why not), at most `logMax` lines a minute, so a missed tap shows.
/// Not yet tried on a Mac with glasses.
public struct GlassesTaps: Sendable {
    public static let g = 9.81
    public static let logG = 0.15 // a jolt starts here (and is logged)
    public static let tapG = 0.25 // a tap's peak, away from the 30 ms average
    public static let jerkG = 0.15 // a tap's jump within jerkS
    public static let jerkS = 0.003
    public static let settleS = 0.008 // a jolt ends after this long under logG
    public static let spikeMaxS = 0.15
    public static let quietBeforeS = 0.06
    public static let turnMax = 60.0 * Double.pi / 180 // rad/s
    public static let tapGapMinS = 0.2
    public static let tapGapMaxS = 0.7
    public static let runEndS = 0.75
    public static let warmupS = 0.5
    public static let avgS = 0.03
    public static let turnAvgS = 0.15
    /// Tap sensitivity's range, percent; 100 is the values above.
    public static let sensitivityRange = 25.0...300.0
    /// Jolt lines a minute.
    public static let logMax = 120

    private struct Jolt: Sendable {
        var start: Double
        var peak: Double
        var jerk: Double
        var turn: Double
        var quiet: Double
        var under: Double?
    }

    public private(set) var sensitivity = 100
    public private(set) var tapG = GlassesTaps.tapG
    public private(set) var jerkG = GlassesTaps.jerkG
    public private(set) var logG = GlassesTaps.logG

    private var t0: Double?
    private var lastT: Double?
    private var avg = SIMD3<Double>(0, 0, 0)
    private var turn = 0.0
    /// (time, acceleration) of the last few reports, for the 3 ms jump.
    private var recent: [(Double, SIMD3<Double>)] = []
    /// When the last jolt ended.
    private var quietFrom = -1e9
    private var jolt: Jolt?
    /// Start times of this run's taps.
    private var taps: [Double] = []
    /// Times of the lines logged, for logMax; and the lines waiting to be taken.
    private var logged: [Double] = []
    private var lines: [String] = []

    public init(sensitivity: Double = 100) {
        setSensitivity(sensitivity)
    }

    /// Tap sensitivity, percent ([sensitivityRange]); anything else, or not a number, is brought inside it (100).
    public mutating func setSensitivity(_ percent: Double) {
        let p = percent.isNaN ? 100 : min(max(percent, Self.sensitivityRange.lowerBound), Self.sensitivityRange.upperBound)
        sensitivity = Int(p.rounded())
        let k = 100 / p
        tapG = Self.tapG * k
        jerkG = Self.jerkG * k
        logG = min(Self.logG, tapG * 0.6)
    }

    /// Starts again (a new stream, or a gap in the reports); the sensitivity and the log's count are kept.
    public mutating func reset() {
        t0 = nil
        lastT = nil
        avg = .zero
        turn = 0
        recent = []
        quietFrom = -1e9
        jolt = nil
        taps = []
    }

    /// Whether a jolt is being followed (for the checks).
    public var inJolt: Bool { jolt != nil }

    /// The log lines since the last call.
    public mutating func takeLog() -> [String] {
        defer { lines = [] }
        return lines
    }

    /// One motion report: [t] in seconds, gyro in rad/s, accelerometer in m/s². Returns 2 or 3 when a run of that many
    /// taps has just ended, else nil.
    public mutating func feed(t: Double, gyro: SIMD3<Double>, accel: SIMD3<Double>) -> Int? {
        guard let last = lastT, t - last > 0, t - last < 0.1 else {
            // The first report, or a gap in the reports: start again.
            reset()
            t0 = t
            lastT = t
            avg = accel
            recent = [(t, accel)]
            return nil
        }
        let dt = t - last
        lastT = t
        let diff = accel - avg
        let d = (diff * diff).sum().squareRoot() / Self.g
        avg += diff * (1 - exp(-dt / Self.avgS))
        var old: SIMD3<Double>?
        for (tt, a) in recent.reversed() where t - tt >= Self.jerkS {
            old = a
            break
        }
        let jump = old.map { o -> Double in let j = accel - o; return (j * j).sum().squareRoot() / Self.g } ?? 0
        recent.append((t, accel))
        while recent.count > 2 && t - recent[1].0 >= Self.jerkS { recent.removeFirst() }
        let w = (gyro * gyro).sum().squareRoot()
        let turnBefore = turn
        turn += (w - turn) * (1 - exp(-dt / Self.turnAvgS))
        if t - (t0 ?? t) < Self.warmupS {
            quietFrom = t
            return nil
        }
        if var j = jolt {
            j.peak = max(j.peak, d)
            j.jerk = max(j.jerk, jump)
            if d >= logG {
                j.under = nil
            } else if j.under == nil {
                j.under = t
            }
            if let under = j.under, t - under >= Self.settleS {
                jolt = nil
                quietFrom = t
                judge(j, lasted: under - j.start)
            } else if t - j.start > 0.3 {
                jolt = nil
                quietFrom = t
                judge(j, lasted: (j.under ?? t) - j.start)
            } else {
                jolt = j
            }
        } else if d >= logG {
            jolt = Jolt(start: t, peak: d, jerk: jump, turn: turnBefore, quiet: t - quietFrom, under: nil)
        }
        if let lastTap = taps.last, jolt == nil, t - lastTap > Self.runEndS {
            let n = taps.count
            taps = []
            if n == 2 || n == 3 { return n }
            log(t, "taps: a run of \(n) ended: only two or three do something")
        }
        return nil
    }

    private mutating func judge(_ j: Jolt, lasted: Double) {
        let gap = taps.last.map { j.start - $0 }
        var why: String?
        if j.peak < tapG {
            why = "too soft (under \(Self.f2(tapG)) g)"
        } else if j.jerk < jerkG {
            why = "not sharp (a tap jumps \(Self.f2(jerkG)) g within \(Self.ms(Self.jerkS)) ms)"
        } else if lasted > Self.spikeMaxS {
            why = "too long (a tap is under \(Self.ms(Self.spikeMaxS)) ms)"
        } else if j.quiet < Self.quietBeforeS {
            why = "too soon after other movement (needs \(Self.ms(Self.quietBeforeS)) ms still)"
        } else if j.turn >= Self.turnMax {
            why = "the head was turning (over \(Int((Self.turnMax * 180 / .pi).rounded())) deg/s)"
        } else if let gap, gap < Self.tapGapMinS {
            why = "too soon after the last tap (under \(Self.ms(Self.tapGapMinS)) ms)"
        }
        let verdict: String
        if let why {
            verdict = "not a tap: " + why
        } else {
            if let gap, gap > Self.tapGapMaxS { taps = [] }
            taps.append(j.start)
            verdict = "a tap, \(taps.count) in this run"
        }
        let gapText = gap.map { "\(Int(($0 * 1000).rounded())) ms" } ?? "none"
        log(j.start, "taps: jolt \(Self.f2(j.peak)) g (jump \(Self.f2(j.jerk)) g in 3 ms), \(Int((lasted * 1000).rounded())) ms, "
            + "still \(Int((min(j.quiet, 9.99) * 1000).rounded())) ms before, head turning "
            + "\(Int((j.turn * 180 / .pi).rounded())) deg/s, last tap \(gapText) before: \(verdict)")
    }

    private mutating func log(_ t: Double, _ line: String) {
        logged = logged.filter { t - $0 < 60 }
        guard logged.count < Self.logMax else { return }
        logged.append(t)
        lines.append(line)
    }

    private static func f2(_ x: Double) -> String { String(format: "%.2f", x) }
    private static func ms(_ s: Double) -> String { String(format: "%g", s * 1000) }

    /// The menu's and the log's word for what a run of [n] taps does.
    public static func jobName(_ n: Int) -> String {
        switch n {
        case 2: return "recentre"
        case 3: return "switch view"
        default: return "nothing"
        }
    }
}
