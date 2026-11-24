import Foundation

// Taps on the glasses (GlassesTaps), with made-up motion: Pocket XR for Steam Deck 0.7.11's tests
// (tests/test_tester_fixes_075.py, _077.py and _0711.py), ported. Not real taps: not yet tried on a Mac with glasses.

private let tapHz = 1000.0 // the XBX sends about 1000 reports a second

/// Feeds GlassesTaps a head at rest (gravity along y) plus [accel] (in g) and [gyro] (deg/s), with a tap of [tapG] for
/// [tapS] at each time in [tapsAt], the frame ringing on after it at [ringG] until [ringS]; returns the runs it
/// reported, and the log lines in [lines].
private func runTaps(_ seconds: Double, accel: (Double) -> SIMD3<Double> = { _ in .zero },
                     gyro: (Double) -> SIMD3<Double> = { _ in .zero }, tapsAt: [Double] = [], tapG: Double = 2.0,
                     tapS: Double = 0.004, ringG: Double = 0.1, ringS: Double = 0.04, sensitivity: Double = 100,
                     hz: Double = tapHz, lines: UnsafeMutablePointer<[String]>? = nil) -> [Int] {
    var got: [Int] = []
    var taps = GlassesTaps(sensitivity: sensitivity)
    let n = Int(seconds * hz)
    for i in 0..<n {
        let t = Double(i) / hz
        var a = accel(t)
        a.y += 1
        for at in tapsAt {
            if at <= t && t < at + tapS {
                a.z += tapG
            } else if at + tapS <= t && t < at + ringS { // the frame ringing on after the tap
                a.z += ringG * sin((t - at) * 2 * .pi * 150)
            }
        }
        let w = gyro(t) * (.pi / 180)
        if let r = taps.feed(t: 100 + t, gyro: w, accel: a * GlassesTaps.g) { got.append(r) }
        lines?.pointee.append(contentsOf: taps.takeLog())
    }
    return got
}

func tapChecks() {
    check(!SpaceSettings().glassesTaps, "taps on the glasses are off by default")
    check(SpaceSettings().tapSensitivity == 100, "tap sensitivity is 100% by default")
    let old = try? JSONDecoder().decode(SpaceSettings.self, from: Data(#"{"screens": 2}"#.utf8))
    check(old?.glassesTaps == false && old?.tapSensitivity == 100, "an older settings file leaves taps off, at 100%")
    var on = SpaceSettings()
    on.glassesTaps = true
    on.tapSensitivity = 175
    let back = try? JSONDecoder().decode(SpaceSettings.self, from: (try? JSONEncoder().encode(on)) ?? Data())
    check(back?.glassesTaps == true && back?.tapSensitivity == 175, "taps and their sensitivity are saved and read back")
    var wild = SpaceSettings()
    wild.tapSensitivity = 1000
    check(wild.clamped.tapSensitivity == 300, "a sensitivity over 300% is brought to 300")
    wild.tapSensitivity = .nan
    check(wild.clamped.tapSensitivity == 100, "no number is 100%")

    // Two and three taps; one, four, or two too far apart do nothing.
    check(runTaps(2.5, tapsAt: [1.0, 1.25]) == [2], "two taps")
    check(runTaps(2.5, tapsAt: [1.0, 1.3, 1.6]) == [3], "three taps")
    check(runTaps(2.5, tapsAt: [1.0]) == [], "one tap does nothing")
    check(runTaps(3.0, tapsAt: [1.0, 1.25, 1.5, 1.75]) == [], "four taps do nothing")
    check(runTaps(3.0, tapsAt: [1.0, 1.9]) == [], "slow taps are not a run")
    check(runTaps(2.5, tapsAt: [1.0, 1.3], hz: 250) == [2], "two taps at 250 reports a second")

    // Soft jolts and pushes are not taps.
    check(runTaps(2.5, tapsAt: [1.0, 1.25], tapG: 0.2) == [], "a soft jolt is not a tap")
    let push: (Double) -> SIMD3<Double> = { t in // a smooth 2 g swell over 250 ms, twice
        let p = t - (t < 1.6 ? 1.0 : 1.6)
        return SIMD3(0, 0, p >= 0 && p < 0.25 ? 2 * sin(.pi * p / 0.25) : 0)
    }
    check(runTaps(2.5, accel: push) == [], "a push is not a tap")

    // The first half second is skipped (the XBX's first report is a junk value).
    check(runTaps(1.5, tapsAt: [0.05, 0.25]) == [], "the first half second is skipped")

    // Head turns: side to side up to 150 deg/s with some tilt, nothing; taps during a fast turn are left out.
    let turning: (Double) -> SIMD3<Double> = { t in SIMD3(0, 150 * sin(t * 2 * .pi * 0.7), 0) }
    let tilt: (Double) -> SIMD3<Double> = { t in SIMD3(0.2 * sin(t * 2 * .pi * 0.7), 0, 0.1 * cos(t * 2 * .pi * 0.7)) }
    check(runTaps(6.0, accel: tilt, gyro: turning) == [], "head turns alone are not taps")
    check(runTaps(2.5, gyro: { _ in SIMD3(0, 120, 0) }, tapsAt: [1.0, 1.25]) == [], "taps during a fast turn are left out")

    // Walking: two steps a second, a sway of 0.3 g and a 0.7 g heel strike over 20 ms at each step.
    let steps: (Double) -> SIMD3<Double> = { t in
        let p = t.truncatingRemainder(dividingBy: 0.5)
        let strike = p < 0.02 ? 0.7 * sin(.pi * p / 0.02) : 0
        return SIMD3(0.05 * sin(t * 2 * .pi), 0.3 * sin(t * 4 * .pi) + strike, 0)
    }
    check(runTaps(10.0, accel: steps, gyro: { t in SIMD3(0, 20 * sin(t * 2 * .pi), 0) }) == [], "walking is not taps")
    // Hard steps over the tap level, 100 ms long: not taps.
    let stomps: (Double) -> SIMD3<Double> = { t in
        let p = t.truncatingRemainder(dividingBy: 0.5)
        return SIMD3(0, p < 0.1 ? sin(.pi * p / 0.1) : 0, 0)
    }
    check(runTaps(6.0, accel: stomps) == [], "hard steps are not taps")

    // A gap in the reports starts again: the jump after it is not a tap.
    var taps = GlassesTaps()
    var got: [Int] = []
    for i in 0..<800 {
        if let r = taps.feed(t: Double(i) / tapHz, gyro: .zero, accel: SIMD3(0, GlassesTaps.g, 0)) { got.append(r) }
    }
    if let r = taps.feed(t: 5.0, gyro: .zero, accel: SIMD3(0, GlassesTaps.g, 3 * GlassesTaps.g)) { got.append(r) }
    check(!taps.inJolt && got == [], "a gap in the reports starts again")

    // Soft taps like the tester's on the top of the frame (0.33 to 0.51 g, about 320 ms apart), and 2 a second.
    check(runTaps(3.0, tapsAt: [1.0, 1.32], tapG: 0.35, tapS: 0.005) == [2], "his soft double tap")
    check(runTaps(3.0, tapsAt: [1.0, 1.32, 1.64], tapG: 0.35, tapS: 0.005) == [3], "his soft triple tap")
    check(runTaps(3.0, tapsAt: [1.0, 1.5], tapG: 0.35) == [2], "two taps a second")
    check(runTaps(3.5, tapsAt: [1.0, 1.5, 2.0], tapG: 0.35) == [3], "three taps at two a second")
    // The frame ringing after a tap is part of it, and does not eat the next one.
    check(runTaps(3.0, tapsAt: [1.0, 1.25], tapG: 0.4, ringG: 0.3) == [2], "ringing does not eat the second tap")
    check(runTaps(3.0, tapsAt: [1.0, 1.3, 1.6], tapG: 0.4, ringG: 0.3) == [3], "ringing does not eat the third tap")
    // Firm taps that ring for 100 ms (his lasted up to 101 ms) still count.
    check(runTaps(3.5, tapsAt: [1.0, 1.43, 1.86], tapG: 3.0, ringG: 0.6, ringS: 0.1) == [3], "firm taps ringing 100 ms")
    // Putting the glasses on: two sharp jolts 134 ms apart, not a run.
    check(runTaps(3.0, tapsAt: [1.0, 1.134], tapG: 0.4) == [], "two jolts 134 ms apart are not a run")

    // The values: his taps and cadence inside them, plain head movement outside.
    check(GlassesTaps.tapG <= 0.33 && GlassesTaps.jerkG <= 0.23 && GlassesTaps.jerkG > 0.10, "the tap and jump levels")
    check(GlassesTaps.tapGapMinS <= 0.32 && GlassesTaps.tapGapMaxS >= 0.5 && GlassesTaps.tapGapMinS > 0.134, "the gaps")
    check(GlassesTaps.spikeMaxS >= 0.101 && GlassesTaps.spikeMaxS < 0.25, "a tap's length")

    // Every jolt is logged, with why.
    var lines: [String] = []
    _ = runTaps(3.0, tapsAt: [1.0, 1.3], tapG: 0.35, lines: &lines)
    let jolts = lines.filter { $0.hasPrefix("taps: jolt ") }
    check(jolts.count == 2, "two jolts logged: \(lines)")
    check(jolts.first?.contains("a tap, 1 in this run") == true && jolts.first?.contains("head turning") == true, "the first jolt's line")
    check(jolts.last?.contains("last tap 300 ms before: a tap, 2 in this run") == true, "the second jolt's line: \(jolts)")
    lines = []
    _ = runTaps(3.0, tapsAt: [1.0], tapG: 0.2, lines: &lines)
    check(lines.contains { $0.contains("not a tap: too soft") }, "a soft jolt is logged as too soft: \(lines)")
    lines = []
    _ = runTaps(3.0, tapsAt: [1.0], tapG: 0.4, lines: &lines)
    check(lines.contains("taps: a run of 1 ended: only two or three do something"), "a run of one is logged: \(lines)")
    lines = []
    _ = runTaps(100.0, tapsAt: (0..<100).map { 1.0 + 0.9 * Double($0) }, tapG: 0.4, lines: &lines)
    check(lines.count <= 2 * GlassesTaps.logMax + 2, "the log is capped: \(lines.count) lines")

    // Tap sensitivity: 100 keeps the values; it divides the jolt and jump a tap needs, within 25 to 300%.
    var s = GlassesTaps()
    check(s.sensitivity == 100 && s.tapG == GlassesTaps.tapG && s.jerkG == GlassesTaps.jerkG && s.logG == GlassesTaps.logG,
          "100% keeps the values the tester liked")
    s.setSensitivity(200)
    check(abs(s.tapG - GlassesTaps.tapG / 2) < 1e-12 && abs(s.jerkG - GlassesTaps.jerkG / 2) < 1e-12 && s.logG <= s.tapG,
          "200% halves the tap and jump levels")
    s.setSensitivity(50)
    check(abs(s.tapG - GlassesTaps.tapG * 2) < 1e-12, "50% doubles them")
    s.setSensitivity(1000)
    check(s.sensitivity == 300, "over 300% is 300")
    s.setSensitivity(.nan)
    check(s.sensitivity == 100, "no number is 100%")
    func soft(_ sens: Double, _ g: Double) -> [Int] {
        var t = GlassesTaps(sensitivity: sens)
        var out: [Int] = []
        for i in 0..<Int(3.0 * tapHz) {
            let x = Double(i) / tapHz
            let az = [1.0, 1.3].contains { $0 <= x && x < $0 + 0.004 } ? g : 0
            if let r = t.feed(t: 100 + x, gyro: .zero, accel: SIMD3(0, GlassesTaps.g, az * GlassesTaps.g)) { out.append(r) }
        }
        return out
    }
    check(soft(100, 0.2) == [], "a 0.2 g double tap is too soft at 100%")
    check(soft(200, 0.2) == [2], "it counts at 200%")
    check(soft(50, 0.35) == [], "0.35 g taps are too soft at 50%")
    check(soft(100, 0.35) == [2], "they count at 100%")

    check(GlassesTaps.jobName(2) == "recentre" && GlassesTaps.jobName(3) == "switch view", "the jobs' names")
}
