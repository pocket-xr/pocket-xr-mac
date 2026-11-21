import Foundation

// The head pose chain's checks: the ports of Pocket XR's HeadPrediction, DrawSmoothing0564, RestLock0532 and
// HeadScroll146 tests that need no recorded gyro files, and the whole chain (fusion to drawn pose) on made heads.

/// The same numbers every run, -1 to 1.
private struct TrackingRandom {
    var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let top: UInt64 = state >> 11
        return Double(top) / 9007199254740992.0 * 2 - 1
    }
}

private let trackingRad: Double = Double.pi / 180
private let trackingFrame: Double = 1.0 / 60.0

/// A turn of [deg] degrees to the left.
private func trackingYaw(_ deg: Double) -> Quat { return Quat.aboutY(deg * trackingRad) }

/// Made glasses: 1000 reports a second into a fusion, a frame drawn every 16 ms.
private final class TrackingRig {
    let fusion: HeadFusion
    let pose: HeadPose
    var options: TrackingOptions
    var accel: SIMD3<Double>
    var noise: Double = 0
    var random = TrackingRandom(7)
    var n: Int = 0
    var last: Quat = Quat.identity
    let host0: Double = 1000

    /// The head starts [pitchDeg] up.
    init(pitchDeg: Double = 0) {
        fusion = HeadFusion(axes: .aura)
        pose = HeadPose(fusion: fusion)
        options = TrackingOptions(SpaceSettings())
        let p: Double = pitchDeg * trackingRad
        accel = SIMD3<Double>(0, 9.81 * cos(p), -9.81 * sin(p))
    }

    var now: Double { return host0 + Double(n) / 1000 }

    /// [seconds] of reports with the head turning at [gyro] rad/s; [each] sees every drawn frame.
    func run(_ seconds: Double, gyro: SIMD3<Double> = SIMD3<Double>(0, 0, 0), each: ((Quat) -> Void)? = nil) {
        let steps: Int = Int((seconds * 1000).rounded())
        for _ in 0..<steps {
            n += 1
            var g: SIMD3<Double> = gyro
            if noise > 0 {
                g += SIMD3<Double>(random.next(), random.next(), random.next()) * noise
            }
            let sample = ImuSample(timestampNs: UInt64(n) * 1_000_000, gyro: g, accel: accel)
            fusion.report(sample, arrived: now)
            if n % 16 == 0 {
                last = pose.drawPose(now: now, framePeriod: trackingFrame, options: options)
                if let see = each { see(last) }
            }
        }
    }

    /// The glasses send nothing for [seconds].
    func skip(_ seconds: Double) {
        n += Int((seconds * 1000).rounded())
    }

    func draw() -> Quat {
        last = pose.drawPose(now: now, framePeriod: trackingFrame, options: options)
        return last
    }
}

func trackingChecks() {
    trackingSettingsChecks()
    trackingClockChecks()
    trackingPredictorChecks()
    trackingSmoothingChecks()
    trackingRestLockChecks()
    trackingScrollChecks()
    trackingChainStillChecks()
    trackingChainRecentreChecks()
    trackingChainFollowChecks()
    trackingChainHoldChecks()
    trackingDiagnosticsChecks()
}

private func trackingSettingsChecks() {
    var s = SpaceSettings()
    let d = TrackingOptions(s)
    check(d.headTracking && d.mode == .bodyAnchor && d.drawSmoothing && d.stillLock, "the default settings track, smooth and hold")
    check(d.displayDelayMs == 8 && d.recentreFollowsTilt && !d.headScroll, "the default delay, tilt and Head scroll")
    s.headTracking = false
    s.trackingMode = .smoothFollow
    s.drawSmoothing = false
    s.stillLock = false
    s.displayDelayMs = 12
    s.recentreFollowsTilt = false
    s.headScroll = true
    let o = TrackingOptions(s)
    check(!o.headTracking && o.mode == .smoothFollow && !o.drawSmoothing && !o.stillLock, "the switches are carried over")
    check(o.displayDelayMs == 12 && !o.recentreFollowsTilt && o.headScroll, "the delay, tilt and Head scroll are carried over")
    check(o != d, "options compare by value")
}

private func trackingClockChecks() {
    // 1 kHz samples arriving in 16 ms bursts: after the first burst the offset is the smallest wait, and steady.
    var clock = ImuClock()
    let offset: Int64 = 5_000_000_000
    var lowest: Int64 = Int64.max
    var highest: Int64 = Int64.min
    var sum: Double = 0
    var count: Int = 0
    for i in 0..<2000 {
        let dev: Int64 = Int64(i) * 1_000_000
        let arrived: Int64 = (Int64(i / 16) + 1) * 16_000_000 + 2_000_000 + offset
        let mapped: Int64 = clock.toHost(deviceNs: dev, arrivedNs: arrived) - dev
        if i >= 100 {
            lowest = min(lowest, mapped)
            highest = max(highest, mapped)
            sum += Double(mapped)
            count += 1
        }
    }
    check(highest - lowest < 2_000_000, "the sample clock takes the bursts out")
    check(near(sum / Double(count), Double(offset + 2_000_000), 1_500_000), "the sample clock's offset is the shortest wait")
    // A reconnect with a new device clock starts again.
    let after: Int64 = clock.toHost(deviceNs: 999_000_000_000, arrivedNs: offset + 40_000_000_000)
    check(after == offset + 40_000_000_000, "a jump of the device clock starts the sample clock again")

    check(HeadHold.use(sinceSampleS: 0.02, hasPose: true) == .predict, "fresh samples are predicted from")
    check(HeadHold.use(sinceSampleS: 1.0, hasPose: true) == .hold, "a pause holds the last pose")
    check(HeadHold.use(sinceSampleS: 6.0, hasPose: true) == .none, "a long pause goes head-locked")
    check(HeadHold.use(sinceSampleS: 0.0, hasPose: false) == .none, "no pose, nothing to hold")
}

private func trackingPredictorChecks() {
    // A steady turn at 60 deg/s: the pose 30 ms ahead is the true pose then.
    let p = HeadPredictor()
    let rate: Double = 60 * trackingRad
    var t: Double = 0
    for i in 0..<500 {
        t = Double(i) / 1000
        p.add(Quat.aboutY(rate * t), SIMD3<Double>(0, rate, 0), t)
    }
    check(p.predict(t - 1) == Quat.aboutY(rate * t), "a target before the newest sample gives the sample")
    if let ahead = p.predict(t + 0.030) {
        let error: Double = HeadMath.angleDeg(ahead, Quat.aboutY(rate * (t + 0.030)))
        check(error < 0.01, "a steady turn is predicted 30 ms ahead to \(error) deg")
    } else {
        check(false, "the predictor has a pose")
    }
    if let far = p.predict(t + 0.5) {
        let error: Double = HeadMath.angleDeg(far, Quat.aboutY(rate * (t + 0.080)))
        check(error < 0.01, "prediction stops at 80 ms ahead (\(error) deg off that)")
    }
    check(p.blendShare == 1 && p.stillWeight == 0, "a turning head is predicted in full")

    // A head speeding up: the acceleration's share brings the prediction closer than the rate alone.
    let q = HeadPredictor()
    let speedUp: Double = 4 // rad/s^2
    var angle: Double = 0
    for i in 0..<500 {
        t = Double(i) / 1000
        angle = 0.5 * speedUp * t * t
        q.add(Quat.aboutY(angle), SIMD3<Double>(0, speedUp * t, 0), t)
    }
    let truth: Quat = Quat.aboutY(0.5 * speedUp * (t + 0.030) * (t + 0.030))
    if let ahead = q.predict(t + 0.030) {
        let error: Double = HeadMath.angleDeg(ahead, truth)
        let unpredicted: Double = HeadMath.angleDeg(Quat.aboutY(angle), truth)
        check(error < 0.15 && error < unpredicted / 10, "a head speeding up is predicted to \(error) deg (unpredicted \(unpredicted))")
    }

    // A still head with gyro noise gets next to no prediction noise.
    let still = HeadPredictor()
    var random = TrackingRandom(3)
    var worst: Double = 0
    for i in 0..<2000 {
        t = Double(i) / 1000
        let w = SIMD3<Double>(random.next(), random.next(), random.next()) * 0.003
        still.add(Quat.identity, w, t)
        if i > 1000, let ahead = still.predict(t + 0.030) {
            worst = max(worst, HeadMath.angleDeg(ahead, Quat.identity))
        }
    }
    check(worst < 0.004, "a still head's gyro noise is not pushed ahead (\(worst) deg at most)")

    still.reset()
    check(still.predict(1) == nil, "no pose after a reset")
}

private func trackingSmoothingChecks() {
    // A steady turn: the drawn pose trails by a bounded angle (Pocket XR's bounds).
    let cases: [(rate: Double, most: Double)] = [(20, 1.1), (60, 2.0), (150, 3.2)]
    for c in cases {
        let s = DrawSmoothing()
        var lag: Double = 0
        for i in 0..<120 {
            let t: Double = Double(i) * trackingFrame
            let head: Quat = trackingYaw(c.rate * t)
            lag = HeadMath.angleDeg(s.update(head, t), head)
        }
        check(lag <= c.most && lag > 0, "a turn at \(c.rate) deg/s is drawn \(lag) deg behind")
    }

    // A head held still with jitter: the drawn pose moves far less from frame to frame.
    let jitter = DrawSmoothing()
    var random = TrackingRandom(11)
    var before: Quat?
    var beforeShown: Quat?
    var trackedSq: Double = 0
    var shownSq: Double = 0
    var worstOff: Double = 0
    for i in 0..<240 {
        let t: Double = Double(i) * trackingFrame
        let head: Quat = (trackingYaw(0.03 * random.next()) * Quat.aboutX(0.03 * random.next() * trackingRad)).normalized
        let drawn: Quat = jitter.update(head, t)
        if i > 30, let b = before, let bs = beforeShown {
            let a: Double = HeadMath.angleDeg(b, head)
            let d: Double = HeadMath.angleDeg(bs, drawn)
            trackedSq += a * a
            shownSq += d * d
            worstOff = max(worstOff, HeadMath.angleDeg(drawn, head))
        }
        before = head
        beforeShown = drawn
    }
    check(shownSq.squareRoot() <= 0.35 * trackedSq.squareRoot(), "smoothing cuts a still head's jitter (\(shownSq.squareRoot()) of \(trackedSq.squareRoot()))")
    check(worstOff < 0.1, "the smoothed pose stays with the still head (\(worstOff) deg)")

    // The frame's other poses take the same correction.
    let two = DrawSmoothing()
    var q: Quat = Quat.identity
    for i in 0..<30 {
        q = trackingYaw(Double(i) * 0.5)
        _ = two.update(q, Double(i) * trackingFrame)
    }
    let shown: Quat = two.update(q, 30 * trackingFrame)
    check(HeadMath.angleDeg(two.apply(q), shown) < 1e-6, "another pose of the frame gets the frame's correction")
    let again: Quat = two.update(q, 30 * trackingFrame)
    check(HeadMath.angleDeg(again, shown) < 1e-6, "a second update for the same frame redoes the step, it does not step again")

    // Off or freed, the head passes as it is.
    let off = DrawSmoothing()
    _ = off.update(Quat.identity, 0)
    let turned: Quat = trackingYaw(10)
    off.free()
    check(off.update(turned, trackingFrame) == turned, "freed, smoothing starts from the head")
    off.enabled = false
    let more: Quat = trackingYaw(20)
    check(off.update(more, 2 * trackingFrame) == more && off.apply(more) == more, "off, smoothing passes the head through")
    // A stall starts from the head too.
    let stall = DrawSmoothing()
    _ = stall.update(Quat.identity, 0)
    _ = stall.update(Quat.identity, trackingFrame)
    check(stall.update(turned, 1.0) == turned, "after a 0.2 s gap smoothing starts from the head")
}

private func trackingRestLockChecks() {
    // A still head with small jitter is held: the drawn pose does not move at all.
    let lock = RestLock()
    var random = TrackingRandom(5)
    var t: Double = 0
    var heldPose: Quat?
    var moved: Double = 0
    var trackedMoved: Double = 0
    for i in 0..<120 {
        let head: Quat = (trackingYaw(0.02 * random.next()) * Quat.aboutX(0.02 * random.next() * trackingRad)).normalized
        let drawn: Quat = lock.update(head, t)
        if i == 30 { heldPose = drawn }
        if i > 30, let h = heldPose {
            moved = max(moved, HeadMath.angleDeg(h, drawn))
            trackedMoved = max(trackedMoved, HeadMath.angleDeg(h, head))
        }
        t += trackingFrame
    }
    check(lock.locked, "a still head with jitter is held")
    check(moved < 1e-6 && trackedMoved > 0.005, "the held picture does not move (\(moved) deg) while the head jitters (\(trackedMoved) deg)")

    // A turn lets go at once and tracks exactly after the fade.
    let turn = RestLock()
    var q: Quat = Quat.identity
    t = 0
    for _ in 0..<60 {
        _ = turn.update(q, t)
        t += trackingFrame
    }
    check(turn.locked, "a second of stillness is held")
    let step: Quat = trackingYaw(1) // 60 deg/s
    var maxOff: Double = 0
    var framesHeld: Int = 0
    for _ in 0..<30 {
        q = (q * step).normalized
        let drawn: Quat = turn.update(q, t)
        if turn.locked { framesHeld += 1 }
        maxOff = max(maxOff, HeadMath.angleDeg(drawn, q))
        t += trackingFrame
    }
    check(framesHeld <= 1, "a turn lets go within its first frame (\(framesHeld) held)")
    check(maxOff <= 1.01, "never more than the lock's limit behind (\(maxOff) deg)")
    q = (q * step).normalized
    check(HeadMath.angleDeg(turn.update(q, t), q) < 1e-3, "after the fade the drawn pose is the head")

    // A slow drift is followed without a visible step.
    let drift = RestLock()
    q = Quat.identity
    t = 0
    var prevShown: Quat?
    var maxStep: Double = 0
    let creep: Quat = trackingYaw(0.2 / 60)
    for _ in 0..<180 {
        q = (q * creep).normalized
        let drawn: Quat = drift.update(q, t)
        if let p = prevShown { maxStep = max(maxStep, HeadMath.angleDeg(p, drawn)) }
        prevShown = drawn
        t += trackingFrame
    }
    check(drift.locked, "a slow drift stays held")
    check(maxStep <= 0.014, "a slow drift is followed in steps of \(maxStep) deg at most")
    if let p = prevShown { check(HeadMath.angleDeg(p, q) <= 1.01, "the held pose stays within the limit of the head") }

    // The frame's other poses get the held pose; the switch turns the lock off.
    let rows = RestLock()
    t = 0
    for _ in 0..<60 {
        _ = rows.update(Quat.identity, t)
        t += trackingFrame
    }
    let row: Quat = trackingYaw(0.03)
    check(HeadMath.angleDeg(rows.apply(row), Quat.identity) < 1e-6, "another pose of a held frame is the held pose")
    rows.enabled = false
    _ = rows.update(row, t)
    check(!rows.locked && HeadMath.angleDeg(rows.apply(row), row) < 1e-6, "off, the lock passes the head through")
}

private func trackingScrollChecks() {
    let s = HeadScroll()
    check(s.step(offsetYawDeg: 5, pitchDeg: 0, dtS: trackingFrame) == 0, "inside the dead zone nothing scrolls")
    var total: Double = 0
    for _ in 0..<120 { total += s.step(offsetYawDeg: 20, pitchDeg: 0, dtS: trackingFrame) }
    check(near(s.speedDegS, 30, 0.5), "10 deg past the dead zone scrolls at 30 deg/s (\(s.speedDegS))")
    check(total > 40 && total < 60, "two seconds of it scroll \(total) deg")
    for _ in 0..<90 { _ = s.step(offsetYawDeg: 0, pitchDeg: 0, dtS: trackingFrame) }
    check(s.speedDegS == 0, "looking back to the middle stops the scroll")
    check(HeadScroll.targetSpeed(offsetYawDeg: 100, pitchDeg: 0) == 45, "the scroll speed has a limit")
    check(HeadScroll.targetSpeed(offsetYawDeg: -100, pitchDeg: 0) == -45, "and the same to the left")
    check(HeadScroll.targetSpeed(offsetYawDeg: 20, pitchDeg: 40) == 0, "looking far up or down does not scroll")
    check(s.step(offsetYawDeg: 20, pitchDeg: 0, dtS: 0) == 0, "no time, no scroll")
    check(HeadScroll.clamp(viewYawDeg: 40, deltaDeg: 10, lowDeg: -45, highDeg: 45) == 45, "the row stops at its end")
    check(HeadScroll.clamp(viewYawDeg: 50, deltaDeg: 1, lowDeg: -45, highDeg: 45) == 50, "a view past the end goes no further out")
    check(HeadScroll.clamp(viewYawDeg: 50, deltaDeg: -1, lowDeg: -45, highDeg: 45) == 49, "but may come back")
}

/// The whole chain on a still head with gyro noise, then a turn; and head tracking off.
private func trackingChainStillChecks() {
    let rig = TrackingRig()
    rig.noise = 0.003
    rig.run(3.0)
    check(rig.fusion.biasReady, "two still seconds teach the bias")
    check(rig.pose.held, "a still head is held by the Still lock")
    check(abs(rig.pose.reportsPerSecond - 1000) <= 5, "the report rate is measured (\(rig.pose.reportsPerSecond))")
    let heldPose: Quat = rig.last
    var moved: Double = 0
    rig.run(1.0) { q in moved = max(moved, HeadMath.angleDeg(heldPose, q)) }
    check(moved < 1e-6, "the held picture does not move with the gyro's noise (\(moved) deg)")
    check(abs(rig.pose.yawPitchDeg.yaw) < 0.2 && abs(rig.pose.yawPitchDeg.pitch) < 0.2, "a still head reads straight ahead")

    // A turn to the left at 30 deg/s lets go and is followed closely.
    let rate: Double = 30 * trackingRad
    rig.run(0.3, gyro: SIMD3<Double>(0, rate, 0))
    check(!rig.pose.held, "a turn lets the Still lock go")
    rig.run(0.7, gyro: SIMD3<Double>(0, rate, 0))
    let yaw: Double = rig.pose.yawPitchDeg.yaw
    check(near(yaw, 30, 2.0), "a second at 30 deg/s to the left is drawn at \(yaw) deg")

    // Without smoothing and lock the drawn pose is the predicted head: ahead of the measured one in a turn.
    rig.options.drawSmoothing = false
    rig.options.stillLock = false
    // 5000 reports so far; 504 more end on a drawn frame (every 16th), so the frame's pose is from the newest report.
    rig.run(0.504, gyro: SIMD3<Double>(0, rate, 0))
    let plain: Double = rig.pose.yawPitchDeg.yaw
    let measured: Double = (rig.fusion.latest().map { HeadMath.yawPitchDeg($0.orientation).yaw }) ?? 0
    // 1.5 frames and 8 ms at 30 deg/s is 0.99 deg.
    check(near(plain - measured, 0.99, 0.1), "the pose is predicted to the frame's light (\(plain - measured) deg ahead)")
    check(!rig.pose.held, "with the Still lock off nothing is held")

    // Head tracking off: the screens are head-locked.
    rig.options.headTracking = false
    rig.run(0.2, gyro: SIMD3<Double>(0, rate, 0))
    check(rig.last == Quat.identity && !rig.pose.held, "head tracking off gives the identity pose")
    check(rig.pose.yawPitchDeg.yaw == 0 && rig.pose.scrollYawDeg == 0, "and reads straight ahead")
}

private func trackingChainRecentreChecks() {
    // Recentre makes the current heading forward.
    let rig = TrackingRig()
    rig.run(2.5)
    rig.run(0.698, gyro: SIMD3<Double>(0, 1, 0)) // 40 degrees to the left
    rig.run(1.0)
    check(near(rig.pose.yawPitchDeg.yaw, 40, 1.0), "the head turned 40 deg left is drawn there (\(rig.pose.yawPitchDeg.yaw))")
    let before: Int = rig.fusion.recentres
    rig.pose.recentre(yawDeg: 0, followTilt: false)
    rig.run(0.5)
    check(rig.fusion.recentres == before + 1, "one recentre is made")
    check(near(rig.pose.yawPitchDeg.yaw, 0, 0.5), "recentre makes the heading forward (\(rig.pose.yawPitchDeg.yaw))")
    rig.pose.recentre(yawDeg: 10, followTilt: false)
    rig.run(0.5)
    check(near(rig.pose.yawPitchDeg.yaw, 10, 0.5), "recentre with the screens' middle 10 deg left puts the head there (\(rig.pose.yawPitchDeg.yaw))")

    // A head 25 degrees up: the horizon unless recentre follows the tilt.
    let up = TrackingRig(pitchDeg: 25)
    up.run(2.5)
    check(near(up.pose.yawPitchDeg.pitch, 25, 0.5), "a head 25 deg up is drawn so (\(up.pose.yawPitchDeg.pitch))")
    up.pose.recentre(yawDeg: 0, followTilt: false)
    up.run(0.5)
    check(near(up.pose.yawPitchDeg.pitch, 25, 0.5) && up.fusion.recentrePitchDeg == 0, "a plain recentre keeps the screens on the horizon")
    up.pose.recentre(yawDeg: 0, followTilt: true)
    up.run(0.5)
    check(near(up.fusion.recentrePitchDeg, 25, 0.5), "a recentre that follows the tilt takes the head's pitch (\(up.fusion.recentrePitchDeg))")
    check(near(up.pose.yawPitchDeg.pitch, 0, 0.5), "so the screens come to where the head looks (\(up.pose.yawPitchDeg.pitch))")
    check(near(up.pose.yawPitchDeg.yaw, 0, 0.5), "and the heading is forward")

    // Within 15 degrees of level the horizon is kept.
    let low = TrackingRig(pitchDeg: 10)
    low.run(2.5)
    low.pose.recentre(yawDeg: 0, followTilt: true)
    low.run(0.5)
    check(low.fusion.recentrePitchDeg == 0 && near(low.pose.yawPitchDeg.pitch, 10, 0.5), "a head 10 deg up keeps the horizon")
}

private func trackingChainFollowChecks() {
    // Smooth Follow: the screens drift back in front of a head that turned and stayed.
    let rig = TrackingRig()
    rig.options.mode = .smoothFollow
    rig.run(2.5)
    check(near(rig.pose.yawPitchDeg.yaw, 0, 0.2), "Smooth Follow starts with the view as it was")
    rig.run(0.5, gyro: SIMD3<Double>(0, 60 * trackingRad, 0)) // 30 degrees to the left
    let turned: Double = rig.pose.yawPitchDeg.yaw
    check(turned > 12 && turned < 26, "right after the turn the screens are still off to the side (\(turned) deg)")
    rig.run(4.0)
    check(near(rig.pose.yawPitchDeg.yaw, 0, 0.5), "Smooth Follow converges on the head (\(rig.pose.yawPitchDeg.yaw) deg left)")
    check(rig.pose.scrollYawDeg == 0, "Head scroll off shifts nothing")

    // Body Anchor leaves the screens where they are in the room.
    let room = TrackingRig()
    room.run(2.5)
    room.run(0.5, gyro: SIMD3<Double>(0, 60 * trackingRad, 0))
    room.run(4.0)
    check(near(room.pose.yawPitchDeg.yaw, 30, 1.0), "Body Anchor keeps the screens in the room (\(room.pose.yawPitchDeg.yaw))")

    // Head scroll: a head held 20 degrees to the right slides the row until its end.
    let scroll = TrackingRig()
    scroll.options.mode = .smoothFollow
    scroll.options.headScroll = true
    scroll.pose.setScrollRange(lowDeg: -25, highDeg: 25)
    scroll.run(2.5)
    scroll.run(0.5, gyro: SIMD3<Double>(0, -40 * trackingRad, 0)) // 20 degrees to the right
    scroll.run(0.5)
    let slid: Double = scroll.pose.scrollYawDeg
    check(slid > 1, "a head turned right past the dead zone scrolls the row (\(slid) deg)")
    scroll.run(6.0)
    let end: Double = scroll.pose.scrollYawDeg
    check(end >= slid && end <= 25, "the row scrolls on and stops at its end (\(end) deg)")
    scroll.options.headScroll = false
    scroll.run(0.1)
    check(scroll.pose.scrollYawDeg == 0, "Head scroll turned off shifts nothing")
}

private func trackingChainHoldChecks() {
    // The stream stops: the last pose holds for 5 s, then the view is head-locked; it carries on when it is back.
    let rig = TrackingRig()
    rig.run(2.5)
    rig.run(0.349, gyro: SIMD3<Double>(0, 1, 0)) // 20 degrees to the left
    rig.run(1.0)
    check(near(rig.pose.yawPitchDeg.yaw, 20, 1.0), "the head turned 20 deg left is drawn there")
    rig.skip(1.0)
    _ = rig.draw()
    check(near(rig.pose.yawPitchDeg.yaw, 20, 1.0), "a 1 s pause in the stream holds the last pose (\(rig.pose.yawPitchDeg.yaw))")
    rig.skip(5.0)
    check(rig.draw() == Quat.identity, "after 5 s without reports the view is head-locked")
    rig.run(0.2)
    check(near(rig.pose.yawPitchDeg.yaw, 20, 1.0), "the stream back, the pose carries on from where it was (\(rig.pose.yawPitchDeg.yaw))")
}

/// The USB HID diagnostic: rates counted on the tick, the fusion's used and dropped steps, and the report's line.
private func trackingDiagnosticsChecks() {
    var m = RateMeter()
    check(m.update(count: 0, now: 10) == 0, "a new meter reads 0")
    check(m.update(count: 500, now: 10.5) == 0, "under a second, the meter waits")
    check(m.update(count: 1000, now: 11) == 1000, "1000 in a second is 1000 a second (\(m.perSecond))")
    check(m.update(count: 1000, now: 12.25) == 0, "nothing new for a second reads 0")
    check(m.update(count: 3, now: 12.5) == 0 && m.perSecond == 0, "a count gone back (a new reader) starts again")
    check(m.update(count: 123, now: 13.5) == 120, "and counts from there (\(m.perSecond))")

    // Steps 1 ms apart are used; a jump of 1 s, or a time stamp gone back, is dropped. The first sample is no step.
    let f = HeadFusion(axes: .aura)
    let g = SIMD3<Double>(0, 0, 0), a = SIMD3<Double>(0, 9.81, 0)
    for k in 1...10 { f.report(ImuSample(timestampNs: UInt64(k) * 1_000_000, gyro: g, accel: a), arrived: 1) }
    check(f.steps == FusionSteps(used: 9, dropped: 0), "nine steps used, none dropped (\(f.steps))")
    f.report(ImuSample(timestampNs: 1_010_000_000, gyro: g, accel: a), arrived: 2)
    check(f.steps.dropped == 1 && near(f.steps.lastDroppedS ?? 0, 1.0), "a 1 s jump is dropped (\(f.steps))")
    f.report(ImuSample(timestampNs: 1_009_000_000, gyro: g, accel: a), arrived: 2)
    check(f.steps.dropped == 2 && near(f.steps.lastDroppedS ?? 0, -0.001), "a step back is dropped (\(f.steps))")
    f.report(ImuSample(timestampNs: 1_010_000_000, gyro: g, accel: a), arrived: 2)
    check(f.steps.used == 10 && f.steps.dropped == 2, "steps after it are used again (\(f.steps))")

    // The fused samples HeadPose took, read apart from drawn frames.
    let rig = TrackingRig()
    rig.run(0.5)
    check(rig.pose.sampleCount == 499, "HeadPose counts the fused samples it took (\(rig.pose.sampleCount))")

    let line = TrackingDiagnostics.line(hidPerSecond: 1000, fusedPerSecond: 0,
                                        steps: FusionSteps(used: 2100, dropped: 4521, lastDroppedS: 1.0),
                                        clock: "timestamps: ns", framesPerSecond: 120)
    check(line == "USB HID read 1000 samples a second; the fusion used 0 a second; steps: 2100 used, 4521 dropped "
        + "(the last 1000.0 ms after the one before); timestamps: ns; glasses frames drawn: 120 a second",
        "the diagnostic line: \(line)")
    let none = TrackingDiagnostics.line(hidPerSecond: 0, fusedPerSecond: 0, steps: FusionSteps(),
                                        clock: "timestamps: unit not decided yet", framesPerSecond: 0)
    check(none.contains("0 used, 0 dropped;") && !none.contains("the last"), "no dropped step, no last one: \(none)")
}
