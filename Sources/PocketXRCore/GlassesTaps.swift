import Foundation

/// Taps on the glasses, read from their own motion sensor: two taps recentre, three switch the view. Ported with the
/// same values from Pocket XR for Steam Deck (pocketxr/taps.py), asked for by a tester (Pierre Zammit, 23 Nov 2026)
/// so the jobs work with nothing in your hands.
///
/// A tap on the frame is a short, sharp jolt: the acceleration jumps away from its recent average and back within a
/// few hundredths of a second. Head turns and walking move the glasses too, but more slowly. In the Deck's recorded
/// first seconds (an XBX A01+, the head turning up to 93 degrees a second) the acceleration stayed within 0.23 g of its
/// 30 ms average, apart from the first report (a junk value, so the first half second is skipped). So a tap is:
///
/// - the acceleration at least `tapG` away from its 30 ms average,
/// - back under `quietG` within `spikeMaxS`,
/// - after `quietBeforeS` under `quietG` (so a jolt in the middle of shaking or a step is left out),
/// - while the head turned slower than `turnMax` on average over the last 150 ms.
///
/// Taps `tapGapMinS` to `tapGapMaxS` apart make a run; once `runEndS` passes without another, a run of two or three is
/// reported. One tap, or four and more, does nothing.
///
/// The values come from that recording and from what a tap does to a phone's sensor; they are not yet tried with a
/// real tap on glasses (on the Deck either), so the switch is off by default.
public struct GlassesTaps: Sendable {
    public static let g = 9.81
    public static let tapG = 0.8
    public static let quietG = 0.3
    public static let spikeMaxS = 0.04
    public static let quietBeforeS = 0.06
    public static let turnMax = 60.0 * Double.pi / 180 // rad/s
    public static let tapGapMinS = 0.08
    public static let tapGapMaxS = 0.45
    public static let runEndS = 0.5
    public static let warmupS = 0.5
    public static let avgS = 0.03
    public static let turnAvgS = 0.15

    private var t0: Double?
    private var lastT: Double?
    private var avg = SIMD3<Double>(0, 0, 0)
    private var turn = 0.0
    /// When the acceleration was last over quietG (outside a spike).
    private var loudAt = -1e9
    /// While over quietG after a jolt over tapG: when it started, and the head's turn then.
    private var spike: (start: Double, turn: Double)?
    /// Start times of this run's taps.
    private var taps: [Double] = []

    public init() {}

    public mutating func reset() { self = GlassesTaps() }

    /// One motion report: [t] in seconds, gyro in rad/s, accelerometer in m/s². Returns 2 or 3 when a run of that many
    /// taps has just ended, else nil.
    public mutating func feed(t: Double, gyro: SIMD3<Double>, accel: SIMD3<Double>) -> Int? {
        guard let last = lastT, t - last > 0, t - last < 0.1 else {
            // The first report, or a gap in the reports: start again.
            reset()
            t0 = t
            lastT = t
            avg = accel
            return nil
        }
        let dt = t - last
        lastT = t
        let diff = accel - avg
        let d = (diff * diff).sum().squareRoot() / Self.g
        avg += diff * (1 - exp(-dt / Self.avgS))
        let w = (gyro * gyro).sum().squareRoot()
        turn += (w - turn) * (1 - exp(-dt / Self.turnAvgS))
        if t - (t0 ?? t) < Self.warmupS {
            loudAt = t
            return nil
        }
        if let s = spike {
            if d < Self.quietG {
                spike = nil
                if t - s.start <= Self.spikeMaxS && s.turn < Self.turnMax { tap(s.start) }
                loudAt = t
            } else if t - s.start > Self.spikeMaxS {
                loudAt = t // too long for a tap: a push or a knock, wait for it to settle
            }
        } else if d >= Self.tapG && t - loudAt >= Self.quietBeforeS {
            spike = (t, turn)
        } else if d >= Self.quietG {
            loudAt = t
        }
        if let lastTap = taps.last, spike == nil, t - lastTap > Self.runEndS {
            let n = taps.count
            taps = []
            if n == 2 || n == 3 { return n }
        }
        return nil
    }

    private mutating func tap(_ start: Double) {
        if let last = taps.last {
            let gap = start - last
            if gap < Self.tapGapMinS { return } // the same tap ringing on
            if gap > Self.tapGapMaxS { taps = [] }
        }
        taps.append(start)
    }

    /// The menu's and the log's word for what a run of [n] taps does.
    public static func jobName(_ n: Int) -> String {
        switch n {
        case 2: return "recentre"
        case 3: return "switch view"
        default: return "nothing"
        }
    }
}
