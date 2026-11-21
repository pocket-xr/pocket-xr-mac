import Foundation

/// A running count turned into a rate a second, read now and then (the app's tick, 4 times a second), not per drawn
/// frame: so a rate of 0 means nothing came, not that no frame was drawn to count it.
public struct RateMeter: Sendable {
    public private(set) var perSecond = 0
    private var markTime: Double?
    private var markCount = 0

    public init() {}

    /// Takes the running [count] at [now] (seconds). Once a second or more has passed since the last mark, the rate
    /// is worked out again. A count or clock that went backwards (a new reader) starts the meter again from 0.
    @discardableResult
    public mutating func update(count: Int, now: Double) -> Int {
        guard let mark = markTime, now >= mark, count >= markCount else {
            markTime = now
            markCount = count
            perSecond = 0
            return perSecond
        }
        let span = now - mark
        if span >= 1.0 {
            perSecond = Int((Double(count - markCount) / span).rounded())
            markTime = now
            markCount = count
        }
        return perSecond
    }
}

/// The fusion's steps: each sample after the first is a step from the one before, used when the glasses' time
/// stamps put it more than 0 and less than 50 ms after it, dropped otherwise.
public struct FusionSteps: Equatable, Sendable {
    public var used = 0
    public var dropped = 0
    /// The last dropped step's time difference, seconds (negative when the time stamp went backwards).
    public var lastDroppedS: Double?

    public init(used: Int = 0, dropped: Int = 0, lastDroppedS: Double? = nil) {
        self.used = used
        self.dropped = dropped
        self.lastDroppedS = lastDroppedS
    }
}

/// The USB HID head tracking line of the glasses report and the log: what the reader read, what the fusion did with
/// it, the time stamps' unit and whether the glasses are being drawn. For finding where samples stop when a pair reads
/// "0 reports a second" (an XREAL Air on a Mac, November 2026).
public enum TrackingDiagnostics {
    public static func line(hidPerSecond: Int, fusedPerSecond: Int, steps: FusionSteps, clock: String,
                            framesPerSecond: Int) -> String {
        var dropped = "\(steps.dropped) dropped"
        if let d = steps.lastDroppedS { dropped += " (the last \(ms(d)) after the one before)" }
        return "USB HID read \(hidPerSecond) samples a second; the fusion used \(fusedPerSecond) a second; steps: "
            + "\(steps.used) used, \(dropped); \(clock); glasses frames drawn: \(framesPerSecond) a second"
    }

    static func ms(_ s: Double) -> String {
        guard s.isFinite else { return "an unreadable time" }
        return String(format: "%.1f ms", s * 1000)
    }
}
