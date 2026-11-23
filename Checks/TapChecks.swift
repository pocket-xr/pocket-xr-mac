import Foundation

// Taps on the glasses (GlassesTaps), with synthetic motion: the same cases as Pocket XR for Steam Deck's tests
// (tests/test_tester_fixes_075.py). Not real taps: the detector is not yet tried with glasses.

private let tapHz = 1000.0 // the XBX sends about 1000 reports a second

/// Feeds GlassesTaps a head at rest (gravity along y) plus [accel] (in g) and [gyro] (deg/s), with a tap of [tapG] for
/// [tapS] at each time in [tapsAt], ringing down after it; returns the runs it reported.
private func runTaps(_ seconds: Double, accel: (Double) -> SIMD3<Double> = { _ in .zero },
                     gyro: (Double) -> SIMD3<Double> = { _ in .zero }, tapsAt: [Double] = [], tapG: Double = 2.0,
                     tapS: Double = 0.004, t0: Double = 100, hz: Double = tapHz) -> [Int] {
    var got: [Int] = []
    var taps = GlassesTaps()
    let n = Int(seconds * hz)
    for i in 0..<n {
        let t = Double(i) / hz
        var a = accel(t)
        a.y += 1
        for at in tapsAt {
            if at <= t && t < at + tapS {
                a.z += tapG
            } else if at + tapS <= t && t < at + 0.03 { // a quick ringing, well under quietG
                a.z += 0.1 * sin((t - at) * 2 * .pi * 150)
            }
        }
        let w = gyro(t) * (.pi / 180)
        if let r = taps.feed(t: t0 + t, gyro: w, accel: a * GlassesTaps.g) { got.append(r) }
    }
    return got
}

func tapChecks() {
    check(!SpaceSettings().glassesTaps, "taps on the glasses are off by default")
    let old = try? JSONDecoder().decode(SpaceSettings.self, from: Data(#"{"screens": 2}"#.utf8))
    check(old?.glassesTaps == false, "an older settings file leaves taps off")
    var on = SpaceSettings()
    on.glassesTaps = true
    let back = try? JSONDecoder().decode(SpaceSettings.self, from: (try? JSONEncoder().encode(on)) ?? Data())
    check(back?.glassesTaps == true, "taps on is saved and read back")

    // Two and three taps; one, four, or two too far apart do nothing.
    check(runTaps(2.5, tapsAt: [1.0, 1.25]) == [2], "two taps")
    check(runTaps(2.5, tapsAt: [1.0, 1.2, 1.4]) == [3], "three taps")
    check(runTaps(2.5, tapsAt: [1.0]) == [], "one tap does nothing")
    check(runTaps(3.0, tapsAt: [1.0, 1.2, 1.4, 1.6]) == [], "four taps do nothing")
    check(runTaps(3.0, tapsAt: [1.0, 1.7]) == [], "slow taps are not a run")
    // At a quarter of the rate (an Air-family stream can be slower), with a tap lasting one report.
    check(runTaps(2.5, tapsAt: [1.0, 1.25], hz: 250) == [2], "two taps at 250 reports a second")

    // Soft jolts and pushes are not taps.
    check(runTaps(2.5, tapsAt: [1.0, 1.25], tapG: 0.5) == [], "a soft jolt is not a tap")
    check(runTaps(2.5, tapsAt: [1.0, 1.25], tapS: 0.08) == [], "a push is not a tap")

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
    // Hard steps over the tap level, but 50 ms long: not taps.
    let stomps: (Double) -> SIMD3<Double> = { t in
        let p = t.truncatingRemainder(dividingBy: 0.5)
        return SIMD3(0, p < 0.05 ? sin(.pi * p / 0.05) : 0, 0)
    }
    check(runTaps(6.0, accel: stomps) == [], "hard steps are not taps")

    // A gap in the reports starts again: the jump after it is not a tap.
    var taps = GlassesTaps()
    var got: [Int] = []
    for i in 0..<800 {
        if let r = taps.feed(t: Double(i) / tapHz, gyro: .zero, accel: SIMD3(0, GlassesTaps.g, 0)) { got.append(r) }
    }
    if let r = taps.feed(t: 5.0, gyro: .zero, accel: SIMD3(0, GlassesTaps.g, 3 * GlassesTaps.g)) { got.append(r) }
    for i in 1...1500 {
        if let r = taps.feed(t: 5.0 + Double(i) / tapHz, gyro: .zero, accel: SIMD3(0, GlassesTaps.g, 0)) { got.append(r) }
    }
    check(got == [], "a gap in the reports starts again")

    check(GlassesTaps.jobName(2) == "recentre" && GlassesTaps.jobName(3) == "switch view", "the jobs' names")
}
