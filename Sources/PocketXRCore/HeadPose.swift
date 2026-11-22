import Foundation

/// The head tracking choices the pose chain reads each frame, taken from the settings.
public struct TrackingOptions: Equatable, Sendable {
    /// false: identity pose, the screens are head-locked.
    public var headTracking: Bool
    public var mode: TrackingMode
    public var drawSmoothing: Bool
    public var stillLock: Bool
    /// Extra prediction for the glasses' own delay, milliseconds.
    public var displayDelayMs: Double
    public var recentreFollowsTilt: Bool
    public var headScroll: Bool

    public init(_ s: SpaceSettings) {
        headTracking = s.headTracking
        mode = s.trackingMode
        drawSmoothing = s.drawSmoothing
        stillLock = s.stillLock
        displayDelayMs = s.displayDelayMs
        recentreFollowsTilt = s.recentreFollowsTilt
        headScroll = s.headScroll
    }
}

/// Which screen Smooth Follow brings in front: the one whose middle is nearest where the head looks, kept until the
/// look is clearly nearer another (a tester's Air, 22 Nov 2026: with two screens Smooth Follow held the gap between
/// them in front, so only half of each could be seen, and the screens followed the head so neither could be turned to).
public enum FollowStops {
    /// Of the screens' middles [stopsDeg] (yaw, left positive), the one to bring in front for a look at [lookYawDeg].
    /// [current] is kept unless another is nearer by more than [hysteresisDeg]. nil when there are no screens.
    public static func pick(lookYawDeg: Double, current: Int?, stopsDeg: [Double], hysteresisDeg: Double) -> Int? {
        guard !stopsDeg.isEmpty else { return nil }
        var nearest = 0
        for i in stopsDeg.indices where abs(lookYawDeg - stopsDeg[i]) < abs(lookYawDeg - stopsDeg[nearest]) { nearest = i }
        if let c = current, c < stopsDeg.count, c != nearest,
           abs(lookYawDeg - stopsDeg[nearest]) + hysteresisDeg >= abs(lookYawDeg - stopsDeg[c]) {
            return c
        }
        return nearest
    }

    /// How much nearer another screen must be before Smooth Follow moves to it: a sixth of the closest two screens'
    /// spacing, so a look just past halfway does not flip back and forth. 0 with one screen.
    public static func hysteresisDeg(_ stopsDeg: [Double]) -> Double {
        let sorted = stopsDeg.sorted()
        var gap = Double.infinity
        for i in sorted.indices.dropFirst() where sorted[i] - sorted[i - 1] > 0.01 { gap = min(gap, sorted[i] - sorted[i - 1]) }
        return gap.isFinite ? gap / 6 : 0
    }
}

/// Smooth Follow's anchor, ported from Pocket XR's FollowView (0.5.17, 0.5.38): the anchor eases towards the head's
/// turn since Smooth Follow went on, and the screens are drawn with the head relative to it, so they drift back in
/// front. Starting from the head's pose at the switch keeps the view as it was at that moment. With the screens'
/// middles in [stopsDeg], the view settles on the middle of a whole screen instead ([FollowStops]). Turning the head
/// quickly past halfway to the next screen moves it there, and so does the pointer going onto another screen ([focus]).
struct FollowAnchor {
    /// Pocket XR's FollowView.FOLLOW_RATE: a 0.5 s time constant, chosen by feel.
    static let followRate: Double = 2

    var rate: Double = FollowAnchor.followRate
    /// The screens' middles (yaw, degrees, left positive) the view settles on. Empty: the view as it was at the start.
    var stopsDeg: [Double] = [] {
        didSet { if stopsDeg != oldValue { stop = nil; settling = false } }
    }
    private(set) var stop: Int?
    /// Moving to a screen the pointer went to: the look is not used to choose until the view has come to it.
    private var settling = false
    private var anchor: Quat = Quat.identity
    private var start: Quat?

    /// Moves the anchor on for a frame [dt] seconds long with the tracked pose [q]. With [on] false there is no anchor.
    mutating func update(_ q: Quat, on: Bool, dt: Double) {
        guard on else {
            anchor = Quat.identity
            start = nil
            stop = nil
            settling = false
            return
        }
        var from: Quat = q
        if let s = start {
            from = s
        } else {
            start = q
            anchor = Quat.identity
        }
        // The pose the view settles on: the start, turned so its heading is the chosen screen's middle.
        var settle: Quat = from
        let look: Double = HeadMath.yawPitchDeg(relative(q, on: true)).yaw
        let margin: Double = FollowStops.hysteresisDeg(stopsDeg)
        if settling, let i = stop, i < stopsDeg.count {
            if abs(look - stopsDeg[i]) < max(margin, 1) { settling = false }
        } else {
            settling = false
            stop = FollowStops.pick(lookYawDeg: look, current: stop, stopsDeg: stopsDeg, hysteresisDeg: margin)
        }
        if let i = stop {
            let turn: Double = (stopsDeg[i] - HeadMath.yawPitchDeg(from).yaw) * .pi / 180
            settle = (Quat.aboutY(turn) * from).normalized
        }
        let goal: Quat = (q * settle.conjugate).normalized
        anchor = HeadMath.slerp(anchor, goal, 1 - exp(-dt * rate))
    }

    /// Brings screen [index] in front (the pointer went onto it). Ignored when it is not one of the stops.
    mutating func focus(_ index: Int) {
        guard index >= 0, index < stopsDeg.count, index != stop else { return }
        stop = index
        settling = true
    }

    /// The pose to draw for the tracked pose [q].
    func relative(_ q: Quat, on: Bool) -> Quat {
        return on ? (anchor.conjugate * q).normalized : q
    }

    /// Smooth Follow starts again from the next pose (a recentre).
    mutating func restart() {
        start = nil
        stop = nil
        settling = false
        anchor = Quat.identity
    }
}

/// The orientation the screens are drawn with: Pocket XR's draw chain (HeadTracker.renderPose and the Space's Smooth
/// Follow) in one class. Every sample the fusion makes goes into the predictor; each frame the newest is predicted to
/// the frame's light time, smoothed (DrawSmoothing), held while the head is still (RestLock), and in Smooth Follow
/// taken relative to the anchor that follows the head.
///
/// One HeadPose for a HeadFusion (it takes the fusion's sample sink). Keep both across a reconnect of the glasses, so
/// the last pose is held through the gap. Thread safe: samples come in on the reader's thread, drawPose on the render
/// thread. Nothing is allocated per sample or per frame.
public final class HeadPose: @unchecked Sendable {
    /// The frame's light is taken to leave the glasses this many refresh periods after drawPose (one queued, half the
    /// frame's own scan-out), plus the glasses' delay.
    public static let pipelineFrames: Double = 1.5

    private let fusion: HeadFusion
    private let lock = NSLock()
    private let predictor = HeadPredictor()
    private let smoothing = DrawSmoothing()
    private let restLock = RestLock()
    private let scroll = HeadScroll()
    private var follow = FollowAnchor()

    // All below are read and written with the lock held.
    private var lastSampleTime: Double = 0
    private var hasSample: Bool = false
    private var recentresSeen: Int = -1
    private var restart: Bool = false
    private var lastFrameTime: Double?
    private var drawn: Quat = Quat.identity
    private var heldNow: Bool = false
    private var scrollYaw: Double = 0
    private var scrollLow: Double = -45
    private var scrollHigh: Double = 45
    private var followStops: [Double] = []
    private var followFocus: Int?
    private var samples: Int = 0
    private var rateMarkTime: Double?
    private var rateMarkSamples: Int = 0
    private var perSecond: Int = 0

    public init(fusion: HeadFusion) {
        self.fusion = fusion
        fusion.setSampleSink { [weak self] (sample: HeadSample) -> Void in
            guard let pose = self else { return }
            pose.take(sample)
        }
    }

    /// One fused sample, on the reader's thread.
    private func take(_ s: HeadSample) {
        lock.lock()
        if s.recentres != recentresSeen {
            // The orientation's frame jumped (a recentre): nothing learnt in the old frame carries over.
            recentresSeen = s.recentres
            predictor.reset()
            restart = true
        }
        if HeadMath.isFinite(s.orientation) && s.rate.x.isFinite && s.rate.y.isFinite && s.rate.z.isFinite {
            predictor.add(s.orientation, s.rate, s.hostTime)
            lastSampleTime = s.hostTime
            hasSample = true
        }
        samples += 1
        lock.unlock()
    }

    /// The orientation to draw the next frame with (head relative to the recentred forward; x right, y up, z back),
    /// called once per frame on the render thread. `now` is ProcessInfo.processInfo.systemUptime in seconds,
    /// `framePeriod` the glasses' refresh period in seconds. The pose is predicted to the middle of the frame's light:
    /// now + 1.5 periods + displayDelayMs, never more than 80 ms past the newest sample.
    public func drawPose(now: Double, framePeriod: Double, options: TrackingOptions) -> Quat {
        lock.lock()
        defer { lock.unlock() }
        measureRate(now)
        var frameDt: Double = 0
        if let last = lastFrameTime { frameDt = HeadMath.clamp(now - last, 0, 0.2) }
        lastFrameTime = now

        guard options.headTracking else { return headLocked() }

        let period: Double = framePeriod.isFinite ? HeadMath.clamp(framePeriod, 0, 0.1) : 1.0 / 60.0
        let delay: Double = options.displayDelayMs.isFinite ? HeadMath.clamp(options.displayDelayMs, 0, 100) / 1000 : 0
        let target: Double = now + HeadPose.pipelineFrames * period + delay

        // A pause in the stream keeps the last pose, unpredicted, for up to HeadHold.holdS; then head-locked.
        let since: Double = hasSample ? now - lastSampleTime : Double.infinity
        var tracked: Quat?
        switch HeadHold.use(sinceSampleS: since, hasPose: predictor.orientation != nil) {
        case .predict: tracked = predictor.predict(target)
        case .hold: tracked = predictor.orientation
        case .none: tracked = nil
        }
        guard let head = tracked, HeadMath.isFinite(head) else { return headLocked() }

        if restart {
            restart = false
            smoothing.free()
            restLock.free()
            follow.restart()
            scroll.stop()
            scrollYaw = 0
        }
        smoothing.enabled = options.drawSmoothing
        let smoothed: Quat = smoothing.update(head, target)
        restLock.enabled = options.stillLock
        let steady: Quat = restLock.update(smoothed, target)
        heldNow = restLock.locked

        let following: Bool = options.mode == .smoothFollow
        follow.rate = options.headScroll ? HeadScroll.followRate : FollowAnchor.followRate
        // Head scroll slides the row itself, so it needs no screen to settle on.
        follow.stopsDeg = options.headScroll ? [] : followStops
        if let f = followFocus {
            followFocus = nil
            if following { follow.focus(f) }
        }
        follow.update(steady, on: following, dt: frameDt)
        let shown: Quat = follow.relative(steady, on: following)

        if following && options.headScroll {
            let look = HeadMath.yawPitchDeg(shown)
            // Pocket XR's Head scroll counts the head's turn right positive.
            let delta: Double = scroll.step(offsetYawDeg: -look.yaw, pitchDeg: look.pitch, dtS: frameDt)
            scrollYaw = HeadScroll.clamp(viewYawDeg: scrollYaw, deltaDeg: delta, lowDeg: scrollLow, highDeg: scrollHigh)
        } else {
            scroll.stop()
            scrollYaw = 0
        }
        drawn = shown
        return shown
    }

    /// No head to draw with (the lock is held): identity, and every stage starts again from the head when it is back.
    private func headLocked() -> Quat {
        smoothing.free()
        restLock.free()
        follow.restart()
        scroll.stop()
        scrollYaw = 0
        heldNow = false
        drawn = Quat.identity
        return Quat.identity
    }

    /// Counts the samples of the last second (the lock is held).
    private func measureRate(_ now: Double) {
        guard let mark = rateMarkTime else {
            rateMarkTime = now
            rateMarkSamples = samples
            return
        }
        let span: Double = now - mark
        if span >= 1.0 || span < 0 {
            perSecond = span > 0 ? Int((Double(samples - rateMarkSamples) / span).rounded()) : 0
            rateMarkTime = now
            rateMarkSamples = samples
        }
    }

    /// Yaw the row of screens should be shifted by for Head scroll, degrees (0 when off). Positive turns the row to
    /// the left about the up axis (as Quat.aboutY), which is what a head turned right asks for: the screens on the
    /// right come towards the middle. Only in Smooth Follow with Head scroll on.
    public var scrollYawDeg: Double {
        lock.lock(); defer { lock.unlock() }
        return scrollYaw
    }

    /// How far Head scroll may shift the row either way, degrees: the first and last screens' middles, so the row
    /// stops at its ends. -45 to 45 until set.
    public func setScrollRange(lowDeg: Double, highDeg: Double) {
        lock.lock(); defer { lock.unlock() }
        scrollLow = min(lowDeg, highDeg)
        scrollHigh = max(lowDeg, highDeg)
        scrollYaw = HeadMath.clamp(scrollYaw, scrollLow, scrollHigh)
    }

    /// The screens' middles (yaw, degrees, left positive) Smooth Follow settles on when Head scroll is off, so a whole
    /// screen is in front rather than the gap between two. Empty until set: the view stays as it was at the start.
    public func setFollowStops(_ yawsDeg: [Double]) {
        lock.lock(); defer { lock.unlock() }
        followStops = yawsDeg.filter(\.isFinite)
    }

    /// The pointer went onto screen [index]: Smooth Follow brings that screen in front (when Head scroll is off).
    public func setFollowFocus(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        followFocus = index
    }

    /// Which of the follow stops Smooth Follow is settling on now, nil when none (for the checks and the log).
    public var followStop: Int? {
        lock.lock(); defer { lock.unlock() }
        return follow.stop
    }

    /// Recentres: the head's heading becomes forward, the view turned `yawDeg` left so the middle of the screens is
    /// ahead; with `followTilt` and the head more than 15 degrees up or down, the screens also come to that pitch.
    /// Takes effect with the glasses' next sample; Smooth Follow and Head scroll start again from there.
    public func recentre(yawDeg: Double, followTilt: Bool) {
        fusion.recentre(yawDeg: yawDeg, followTilt: followTilt)
    }

    /// The Still lock is holding the picture now (for the diagnostics pane).
    public var held: Bool {
        lock.lock(); defer { lock.unlock() }
        return heldNow
    }

    /// The drawn pose's yaw and pitch in degrees (left and up positive), for the status display.
    public var yawPitchDeg: (yaw: Double, pitch: Double) {
        lock.lock(); defer { lock.unlock() }
        return HeadMath.yawPitchDeg(drawn)
    }

    /// Fused samples taken so far, for a rate counted apart from drawn frames (RateMeter).
    public var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Head tracking reports a second, measured over the last second (counted as drawPose is called).
    public var reportsPerSecond: Int {
        lock.lock(); defer { lock.unlock() }
        return perSecond
    }
}
