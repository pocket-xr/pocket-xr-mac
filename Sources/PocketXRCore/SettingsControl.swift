import Foundation

/// The glasses' own settings, kept right for "window in space" and for Steady mode, as Pocket XR does on the phone
/// and the Deck. Ported from the Deck's settingsctl.py and, for Steady mode, from Pocket XR's SteadyMode and
/// GlassesDisplayControl.
///
/// Runs on its own thread. Only commands Pocket XR has proven are sent (ControlWire.sendable), one at a time, at least
/// 3 s apart, each read back (on the Deck a Spatial Anchor set sent within a second of Ultrawide was refused).
///
///   On the Aura:  Spatial Anchor off, Ultrawide off (the app does the head tracking), follow mode, then 3D.
///   Steady mode:  2D, Ultrawide on, Ultrawide's largest screen size, then (6DoF on the Aura) Spatial Anchor on, last.
///                 The glasses then hold one flat canvas themselves, so the app draws head locked (State.steady).
///   Leaving it:   Spatial Anchor off first, Ultrawide off, the screen size and 3D as they were before.
///   Quit:         Steady mode left first, then only what this app changed is put back, then 2 s of waiting.
///
/// Steady mode has been run on the Aura with the phone and the Deck, never yet on a Mac, and never on the One series.
public final class SettingsControl: @unchecked Sendable {
    public struct State: Equatable, Sendable {
        public var link = false
        public var stereo: Int?
        public var anchor: Int?
        public var ultrawide: Int?
        public var busy = false
        /// Steady mode is on and its whole sequence has completed: the glasses hold the canvas, so the app draws head
        /// locked. False again once it has been left (or could not start and was put back).
        public var steady = false
        /// The glasses' screen size (10397), where the model has it: read on the Aura, and on the One series once Steady
        /// mode has been used.
        public var sizeFactor: Double?
        /// The largest screen size of the mode the glasses are in (10396).
        public var sizeMax: Double?
        /// The glasses' space mode (10421): true follow, false hover. Read on the Aura only.
        public var spaceFollow: Bool?
        /// Something the user has to do in the glasses' own menu for Steady mode (6DoF on the One series), else nil.
        public var steadyNote: String?
        public init() {}
    }

    static let setGapS = 3.0
    static let followReadS = 1.5
    static let followRetryS = 3.0
    static let followTries = 3
    static let followCheckS = 5.0
    static let followSettleS = 3.0
    static let sbsTries = 2
    static let sbsDropWindowS = 20.0
    static let tries = 2
    // Steady mode (Pocket XR's GlassesDisplayCommands: STILL_TRIES, ANCHOR_TRIES, STILL_READ_MS).
    static let steadySets = 8
    static let steadyAnchorTries = 2
    static let steadyReadS = 1.0
    /// Pocket XR gives a change 25 s on the phone; here a re-plugged display's link is waited for inside the change, so
    /// it gets longer.
    static let steadyGiveUpS = 75.0
    static let steadyLinkWaitS = 30.0
    /// How long the screen size is waited for in Ultrawide before Steady mode goes on without changing it.
    static let steadySizeWaitS = 6.0

    private enum Job { case apply, restore(() -> Void), steady(Bool), recentre }

    private let glasses: Glasses
    private let onState: @Sendable (State) -> Void
    private let jobsLock = NSLock()
    private var jobs = [Job]()
    private var link: ControlLink?
    private var stopped = false
    private var state = State()
    private var followTriesUsed = 0
    private var lastFollowCheck = Date.distantPast
    private var followSentAt = Date.distantPast
    private var sbsTriesUsed = 0
    private var sbsFirstAt: Date?
    private var weSet3D = false
    /// The last set of any kind, so two are never closer than [setGapS].
    private var lastSetAt = Date.distantPast
    private var linkOpenedAt = Date.distantPast
    // Steady mode. All of it is touched on the settings thread only.
    /// Steady mode is asked for (being entered, or held).
    private var steadyWanted = false
    /// Its sequence completed and the glasses hold the canvas.
    private var steadyHeld = false
    /// The kind it was entered as: coming in the setting decides, going out the kind it was decides.
    private var steadySix = false
    /// Steady mode was used this run, so these glasses' screen size is read too (the One series is otherwise left alone).
    private var steadyUsed = false
    private var before: SteadyPlan.Before?
    private var weChangedSize = false
    private var lastDropAt: Date?
    /// The glasses refused or never answered the screen size on this link: not asked again, nothing there to change.
    private var sizeUnanswered = false
    private var sizeSilent = 0

    /// The app's "3D side by side" setting.
    public var want3D: @Sendable () -> Bool = { true }
    /// The app's "Steady mode in 6DoF" setting. Used only on glasses that can ([Glasses.sixDofCapable]).
    public var steadySixDof: @Sendable () -> Bool = { true }

    public init(glasses: Glasses, onState: @escaping @Sendable (State) -> Void) {
        self.glasses = glasses
        self.onState = onState
    }

    public func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "Pocket XR glasses settings"
        t.start() // each new link applies the settings (open)
    }

    /// Puts the settings right again (after the 3D setting changed).
    public func apply() { enqueue(.apply) }

    /// Puts the glasses back for normal use, then calls [done] (on the settings thread).
    public func restore(done: @escaping () -> Void) {
        // Quitting: setting the glasses up no longer matters, and must not run first. Seen on Windows, 17 Nov 2026:
        // the glasses reconnected a second before a quit, and the set-up it queued asked for 3D after the quit.
        jobsLock.lock()
        leaving = true
        jobs.removeAll(where: { (j: Job) -> Bool in
            switch j {
            case .apply, .steady: return true
            default: return false
            }
        })
        jobs.insert(.restore(done), at: 0)
        jobsLock.unlock()
    }

    /// The glasses are being put back for a quit: a new link sets nothing up.
    private var leaving = false

    /// Queues entering or leaving Steady mode. State.steady turns true when the whole sequence has completed, and
    /// false when it has been left. Only on glasses that are offered it ([Glasses.steadyCapable]); elsewhere nothing
    /// is sent. An earlier request still waiting is replaced.
    public func setSteady(_ on: Bool) {
        jobsLock.lock()
        jobs.removeAll(where: { (j: Job) -> Bool in
            if case .steady = j { return true }
            return false
        })
        jobs.append(.steady(on))
        jobsLock.unlock()
    }

    /// In Steady mode: the glasses' own recentre (10279), which slides their canvas in front of the head. Does nothing
    /// outside Steady mode.
    public func recentreCanvas() {
        jobsLock.lock()
        jobs.removeAll(where: { (j: Job) -> Bool in
            if case .recentre = j { return true }
            return false
        })
        jobs.append(.recentre)
        jobsLock.unlock()
    }

    public func stop() {
        jobsLock.lock(); stopped = true; jobsLock.unlock()
        link?.close()
    }

    private func enqueue(_ j: Job) {
        jobsLock.lock(); jobs.append(j); jobsLock.unlock()
    }

    private func nextJob() -> Job? {
        jobsLock.lock(); defer { jobsLock.unlock() }
        return jobs.isEmpty ? nil : jobs.removeFirst()
    }

    private var isStopped: Bool { jobsLock.lock(); defer { jobsLock.unlock() }; return stopped }

    private func run() {
        while !isStopped {
            if link == nil || link!.closed {
                if !open() {
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
            }
            guard let job = nextJob() else {
                if Date().timeIntervalSince(lastFollowCheck) >= Self.followCheckS {
                    if steadyWanted {
                        // No follow and no 3D ask while Steady mode is held: either takes the Aura out of Ultrawide.
                        keepSteady()
                    } else {
                        keepFollow()
                        keep3D()
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            state.busy = true
            publish()
            switch job {
            case .apply: applyWindowInSpace()
            case .restore(let done):
                restoreGlasses()
                done()
            case .steady(let on):
                if on { enterSteady(fromUser: true) } else { leaveSteady(quitting: false) }
            case .recentre: recentreNow()
            }
            state.busy = false
            publish()
        }
    }

    private func open() -> Bool { openLink(queueApply: true) }

    /// Opens a new control link and reads the settings on it. [queueApply] false inside a Steady mode change, which
    /// carries on by itself on the new link.
    private func openLink(queueApply: Bool) -> Bool {
        guard let l = try? ControlLink() else {
            if state.link { state.link = false; publish() }
            return false
        }
        link = l
        linkOpenedAt = Date()
        sizeUnanswered = false
        sizeSilent = 0
        plog("settings: control link open via \(l.via)")
        followTriesUsed = 0
        sbsTriesUsed = 0
        sbsFirstAt = nil
        read()
        jobsLock.lock(); let quitting = leaving; jobsLock.unlock()
        if queueApply && !quitting { enqueue(.apply) }
        return true
    }

    /// The open link, opening a new one if the old one closed (a display re-plug closes it), for up to [waitS].
    private func liveLink(waitS: Double) -> ControlLink? {
        let end = Date().addingTimeInterval(waitS)
        while !isStopped {
            if let l = link, !l.closed { return l }
            if openLink(queueApply: false) { continue }
            if Date() >= end { return nil }
            Thread.sleep(forTimeInterval: 2)
        }
        return nil
    }

    @discardableResult
    private func read() -> State {
        guard let l = link else { return state }
        state.link = !l.closed
        state.stereo = l.get(ControlWire.stereoGet)?.flag
        state.anchor = l.get(ControlWire.anchorGet)?.flag
        if glasses.managed || steadyUsed { readSize(l) }
        // Ultrawide is read last: when it says on, the size range read beside it is already Ultrawide's own.
        state.ultrawide = l.get(ControlWire.ultrawideGet)?.flag
        publish()
        return state
    }

    /// The screen size and its range (10397, 10396). Glasses that refuse them, or never answer, are not asked again on
    /// this link: they have nothing here to change, and the rest goes on without it.
    private func readSize(_ l: ControlLink) {
        if sizeUnanswered {
            state.sizeFactor = nil
            state.sizeMax = nil
            return
        }
        let range: ControlWire.Answer? = l.get(ControlWire.sizeRange)
        let size: ControlWire.Answer? = l.get(ControlWire.sizeGet)
        guard let r = range, let s = size else {
            state.sizeFactor = nil
            state.sizeMax = nil
            if !l.closed {
                sizeSilent += 1
                if sizeSilent >= 2 {
                    sizeUnanswered = true
                    plog("settings: the glasses do not answer the screen size; it is left alone on this link")
                }
            }
            return
        }
        sizeSilent = 0
        if r.result != 0 || s.result != 0 {
            sizeUnanswered = true
            state.sizeFactor = nil
            state.sizeMax = nil
            plog("settings: the glasses refuse the screen size (results \(r.result), \(s.result)); it is left alone on this link")
            return
        }
        if let v = s.value, v.isFinite { state.sizeFactor = v } else { state.sizeFactor = nil }
        state.sizeMax = ControlWire.believableSize(r.value2)
    }

    private func publish() {
        var s = state
        s.link = link.map { !$0.closed } ?? false
        onState(s)
    }

    /// Waits until [setGapS] has passed since the last set.
    private func paceSet() {
        let wait = Self.setGapS - Date().timeIntervalSince(lastSetAt)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    /// Sets a value, then reads it back until it holds or [setGapS] has passed; tries twice.
    @discardableResult
    private func setAndCheck(_ what: String, get: Int, want: Int, tries: Int = SettingsControl.tries,
                             _ build: @escaping (UInt32) throws -> [UInt8]) -> Bool {
        return setAndHold(what, tries: tries, build, holds: { (l: ControlLink) -> Bool in
            l.get(get)?.flag == want
        })
    }

    /// Sends one set, then asks [holds] until it says yes or [setGapS] has passed; [tries] times at most.
    private func setAndHold(_ what: String, tries: Int, _ build: @escaping (UInt32) throws -> [UInt8],
                            holds: (ControlLink) -> Bool) -> Bool {
        guard let l = link else { return false }
        for attempt in 1...max(1, tries) {
            paceSet()
            plog("settings: \(what) (try \(attempt))")
            _ = try? l.request(what, build)
            lastSetAt = Date()
            let end = Date().addingTimeInterval(Self.setGapS)
            while Date() < end {
                if l.closed {
                    plog("settings: the control link closed after \(what) (the display re-plugging?)")
                    return false
                }
                if holds(l) {
                    // The display may still be re-plugging: the rest of the gap is waited out.
                    Thread.sleep(forTimeInterval: max(0, end.timeIntervalSinceNow))
                    return true
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        plog("settings: \(what) did not read back")
        return false
    }

    /// Sets the glasses' screen size (10398) and reads it back (10397).
    @discardableResult
    private func setSize(_ size: Double, _ what: String) -> Bool {
        guard ControlWire.believableSize(size) != nil else {
            plog("settings: screen size \(size) is not believed; not sent")
            return false
        }
        let asFloat = Float(size)
        return setAndHold(what, tries: 1, { (id: UInt32) throws -> [UInt8] in
            try ControlWire.sizeSetFrame(id, size: asFloat)
        }, holds: { (l: ControlLink) -> Bool in
            guard let a = l.get(ControlWire.sizeGet), a.result == 0, let v = a.value else { return false }
            return abs(v - size) <= SteadyPlan.sizeSame
        })
    }

    private func applyWindowInSpace() {
        if steadyWanted {
            // A new link in Steady mode (the glasses came back from a re-plug, perhaps without Ultrawide): Steady mode is
            // put back, and none of the settings for normal tracking below may fight it.
            enterSteady(fromUser: false)
            return
        }
        let st = read()
        if glasses.managed {
            // 3DoF: the app tracks the head, so the glasses' own hold must be off.
            if st.anchor == 1 {
                setAndCheck("Spatial Anchor off for 3DoF", get: ControlWire.anchorGet, want: 0) { try ControlWire.anchorSetFrame($0, on: false) }
            }
            if st.ultrawide == 1 {
                setAndCheck("Ultrawide off for 3DoF", get: ControlWire.ultrawideGet, want: 0) { try ControlWire.ultrawideSetFrame($0, on: false) }
            }
            keepFollow()
        }
        depth(fresh: true)
        read()
    }

    /// 3D side by side for the Space, or 2D if the user turned it off.
    private func depth(fresh: Bool) {
        guard link != nil, !steadyWanted else { return } // Steady mode needs 2D: a 3D request would switch Ultrawide off
        let st = read()
        if st.ultrawide == 1 { return } // Ultrawide is the user's; a 3D request would switch it off
        if !want3D() {
            if st.stereo == 1 && weSet3D {
                if setAndCheck("2D (3D turned off)", get: ControlWire.stereoGet, want: 0, { try ControlWire.stereoSetFrame($0, sbs: false) }) {
                    weSet3D = false
                }
            }
            return
        }
        if st.stereo == 1 { return }
        if sbsTriesUsed >= Self.sbsTries && (!fresh || sbsFirstAt != nil) { return } // asked already: the mode is the user's
        let wait = Self.followSettleS - Date().timeIntervalSince(followSentAt)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        sbsTriesUsed += 1
        if sbsFirstAt == nil { sbsFirstAt = Date() }
        if setAndCheck("3D side by side (ask \(sbsTriesUsed))", get: ControlWire.stereoGet, want: 1, { try ControlWire.stereoSetFrame($0, sbs: true) }) {
            weSet3D = true
        }
    }

    /// If the glasses drop 3D straight after taking it (the Aura can, 1 to 5 s after a plug-in), ask once more.
    private func keep3D() {
        guard !steadyWanted else { return }
        guard let first = sbsFirstAt, Date().timeIntervalSince(first) <= Self.sbsDropWindowS else { return }
        if sbsTriesUsed < Self.sbsTries && want3D() { depth(fresh: false) }
    }

    /// On the Aura: follow mode, so the glasses do not hold the picture against the app's tracking. Never in Steady
    /// mode or in Ultrawide: a follow takes the Aura out of Ultrawide.
    private func keepFollow() {
        lastFollowCheck = Date()
        guard glasses.managed, !steadyWanted, let l = link, !l.closed else { return }
        guard followTriesUsed < Self.followTries, state.ultrawide != 1 else { return }
        let mode: Int? = l.get(ControlWire.spaceModeGet)?.flag
        noteSpaceMode(mode)
        if mode == ControlWire.spaceFollow { return }
        followTriesUsed += 1
        paceSet()
        plog("settings: the glasses are in hover; follow mode (try \(followTriesUsed))")
        _ = try? l.request("follow") { try ControlWire.followFrame($0) }
        followSentAt = Date()
        lastSetAt = followSentAt
        Thread.sleep(forTimeInterval: Self.followReadS)
        let after: Int? = l.get(ControlWire.spaceModeGet)?.flag
        noteSpaceMode(after)
        if after == ControlWire.spaceFollow {
            plog("settings: follow mode holds")
        } else {
            Thread.sleep(forTimeInterval: max(0, Self.followRetryS - Self.followReadS))
        }
    }

    private func noteSpaceMode(_ mode: Int?) {
        let follow: Bool? = mode.map { $0 == ControlWire.spaceFollow }
        if follow != state.spaceFollow {
            state.spaceFollow = follow
            publish()
        }
    }

    // MARK: Steady mode

    /// Enters Steady mode, or puts it back on a new link. [fromUser] true for the user's own request, where the
    /// "Steady mode in 6DoF" setting decides the kind again.
    private func enterSteady(fromUser: Bool) {
        guard glasses.steadyCapable else {
            plog("settings: Steady mode is not offered on \(glasses.name); nothing sent")
            return
        }
        steadyUsed = true
        let first = !steadyWanted
        if first || fromUser { steadySix = steadySixDof() && glasses.sixDofCapable }
        if first {
            // What was there before, so leaving puts it back.
            let st = read()
            before = SteadyPlan.Before(stereo: st.stereo, ultrawide: st.ultrawide, size: st.sizeFactor, our3D: weSet3D)
            lastDropAt = nil
            weChangedSize = false
            let plan: [SteadyPlan.Step] = SteadyPlan.steps(entering: true, sixDof: steadySix, state: st, appAnchor: glasses.appAnchor)
            let kind: String = steadySix ? "6DoF" : "3DoF"
            plog("settings: Steady mode on (\(kind)) for \(glasses.name); plan \(Self.names(plan))")
        }
        steadyWanted = true
        state.steadyNote = nil
        if runSteady(on: true) {
            steadyHeld = true
            state.steady = true
            // On the One series the user turns the glasses' own 6DoF on; Pocket XR has no confirmed command for it.
            if steadySix && !glasses.appAnchor { state.steadyNote = SteadyPlan.turnOn6DoF }
            let st = read()
            plog("settings: Steady mode on: done (Ultrawide \(Self.show(st.ultrawide)), screen size \(Self.show(st.sizeFactor)), Spatial Anchor \(Self.show(st.anchor)))")
        } else {
            plog("settings: Steady mode did not start; putting the glasses back")
            leaveSteady(quitting: false)
        }
    }

    /// Leaves Steady mode: Spatial Anchor off first (6DoF on the Aura), Ultrawide off, then the screen size and 3D as
    /// they were before. [quitting] leaves out follow mode and the usual 3D ask.
    private func leaveSteady(quitting: Bool) {
        guard steadyWanted || steadyHeld else {
            plog("settings: Steady mode is not on; nothing sent")
            return
        }
        let was = before
        var st = read()
        let plan: [SteadyPlan.Step] = SteadyPlan.steps(entering: false, sixDof: steadySix, state: st, appAnchor: glasses.appAnchor, before: was)
        plog("settings: Steady mode off; plan \(Self.names(plan))")
        // Ultrawide was on before, with a size of its own: that size goes back while the glasses are still in Ultrawide.
        if weChangedSize, let b = was, b.ultrawide == 1, st.ultrawide == 1,
           let old = SteadyPlan.sizeToPutBack(before: b.size, now: st.sizeFactor) {
            if setSize(old, String(format: "screen size back to %.2f, as before Steady mode", old)) { weChangedSize = false }
        }
        let left = runSteady(on: false)
        st = read()
        if !left || st.ultrawide == 1 {
            plog("settings: Steady mode off: the change did not complete (Ultrawide \(Self.show(st.ultrawide)))")
            if st.ultrawide == 1 {
                // The glasses still hold the canvas, so the app goes on drawing for it.
                steadyWanted = true
                steadyHeld = true
                state.steady = true
                publish()
                return
            }
        }
        steadyWanted = false
        steadyHeld = false
        state.steady = false
        state.steadyNote = (steadySix && !glasses.appAnchor && !quitting) ? SteadyPlan.turnOff6DoF : nil
        if weChangedSize, let b = was, b.ultrawide != 1,
           let old = SteadyPlan.sizeToPutBack(before: b.size, now: st.sizeFactor) {
            // Each mode keeps its own size on the Aura, so this is seldom needed.
            setSize(old, String(format: "screen size back to %.2f, as before Steady mode", old))
        }
        weChangedSize = false
        before = nil
        // Coming out, follow and 3D are asked for again as on a new plug-in.
        followTriesUsed = 0
        sbsTriesUsed = 0
        sbsFirstAt = nil
        if !quitting {
            if glasses.managed { keepFollow() }
            depth(fresh: true)
        }
        // 3D that was the user's own before Steady mode (not asked for by this app) goes back, and stays theirs.
        if let b = was, b.stereo == 1, !b.our3D {
            let now = read()
            if now.stereo != 1 && now.ultrawide != 1 {
                let wait = Self.followSettleS - Date().timeIntervalSince(followSentAt)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                setAndCheck("3D side by side, as before Steady mode", get: ControlWire.stereoGet, want: 1) { try ControlWire.stereoSetFrame($0, sbs: true) }
            }
            weSet3D = false
        }
        let end = read()
        plog("settings: Steady mode off: done (Ultrawide \(Self.show(end.ultrawide)), 2D / 3D \(Self.show(end.stereo)), Spatial Anchor \(Self.show(end.anchor)))")
    }

    /// One Steady mode change, a set at a time: the settings are read, the next step decided from them
    /// (SteadyPlan.next), that one set sent and read back, and so on until nothing is left. A step that will not hold
    /// is sent again from the next reading, up to [steadySets] sets in all. True when the glasses read as wanted.
    private func runSteady(on: Bool) -> Bool {
        let sixDof = steadySix
        let appAnchor = glasses.appAnchor
        let started = Date()
        var sets = 0
        var anchorTries = 0
        var sizeWaitFrom: Date?
        var sizeSkipLogged = false
        while !isStopped {
            guard liveLink(waitS: Self.steadyLinkWaitS) != nil else {
                plog("settings: Steady mode \(on ? "on" : "off"): no control link for \(Int(Self.steadyLinkWaitS)) s")
                return false
            }
            var r = read()
            // Past its tries, Spatial Anchor counts as set the way this change wants it, so the change can finish.
            if anchorTries >= Self.steadyAnchorTries { r.anchor = (on && sixDof) ? 1 : 0 }
            if on && r.ultrawide == 1 && (r.sizeFactor == nil || r.sizeMax == nil) {
                let from = sizeWaitFrom ?? Date()
                sizeWaitFrom = from
                if sizeUnanswered || Date().timeIntervalSince(from) >= Self.steadySizeWaitS {
                    if !sizeSkipLogged {
                        sizeSkipLogged = true
                        plog("settings: the screen size was not read; Steady mode goes on with the size as it is")
                    }
                    r.sizeFactor = 1
                    r.sizeMax = 1
                }
            }
            let step = SteadyPlan.next(on: on, state: r, sixDof: sixDof, appAnchor: appAnchor)
            if step == .done { return true }
            if Date().timeIntervalSince(started) > Self.steadyGiveUpS || (step != .wait && sets >= Self.steadySets) {
                plog("settings: Steady mode \(on ? "on" : "off"): gave up at step \(step.rawValue) after \(sets) sets")
                return false
            }
            if step == .wait {
                Thread.sleep(forTimeInterval: Self.steadyReadS)
                continue
            }
            sets += 1
            switch step {
            case .anchorOff:
                anchorTries += 1
                setAndCheck("Spatial Anchor off (10405 = 0)", get: ControlWire.anchorGet, want: 0, tries: 1) { try ControlWire.anchorSetFrame($0, on: false) }
            case .anchorOn:
                anchorTries += 1
                setAndCheck("Spatial Anchor on (10405 = 1), Steady mode in 6DoF", get: ControlWire.anchorGet, want: 1, tries: 1) { try ControlWire.anchorSetFrame($0, on: true) }
            case .leave3D:
                if setAndCheck("2D (10274 = 0), on the way to Ultrawide", get: ControlWire.stereoGet, want: 0, tries: 1, { try ControlWire.stereoSetFrame($0, sbs: false) }) {
                    weSet3D = false
                }
            case .ultrawideOn:
                setAndCheck("Ultrawide on (10278 = 1)", get: ControlWire.ultrawideGet, want: 1, tries: 1) { try ControlWire.ultrawideSetFrame($0, on: true) }
            case .ultrawideOff:
                setAndCheck("Ultrawide off (10278 = 0)", get: ControlWire.ultrawideGet, want: 0, tries: 1) { try ControlWire.ultrawideSetFrame($0, on: false) }
            case .screenMax:
                if let top = r.sizeMax {
                    if setSize(top, String(format: "screen size %.2f, Ultrawide's largest (10398)", top)) { weChangedSize = true }
                }
            case .wait, .done, .sizeBack, .stereoBack:
                break
            }
        }
        return false
    }

    /// Every few seconds in Steady mode: Ultrawide gone off without Pocket XR asking (the glasses' button pressed
    /// twice, or a re-plug) is put back once, and a second time within 30 s ends Steady mode properly, as the user
    /// then wants out (SteadyMode.dropped).
    private func keepSteady() {
        lastFollowCheck = Date()
        guard steadyHeld, let l = link, !l.closed else { return }
        guard let uw = l.get(ControlWire.ultrawideGet)?.flag else { return }
        if uw == 1 { return }
        state.ultrawide = uw
        let now = Date()
        let what = SteadyPlan.dropped(nowS: now.timeIntervalSinceReferenceDate,
                                      lastDropS: lastDropAt?.timeIntervalSinceReferenceDate,
                                      linkOpenedS: linkOpenedAt.timeIntervalSinceReferenceDate)
        // A re-plug is not the user's button, so it does not count toward leaving.
        if what != .replug { lastDropAt = now }
        state.busy = true
        publish()
        switch what {
        case .replug:
            plog("settings: Steady mode: the glasses came back from a re-plug without Ultrawide; putting Steady mode back")
            enterSteady(fromUser: false)
        case .backIn:
            plog("settings: Steady mode: the glasses left Ultrawide by themselves (their button?); putting it back")
            enterSteady(fromUser: false)
        case .leave:
            plog("settings: Steady mode: the glasses left Ultrawide again within \(Int(SteadyPlan.secondDropS)) s; ending Steady mode properly")
            leaveSteady(quitting: false)
        }
        state.busy = false
        publish()
    }

    /// The glasses' own recentre of their Ultrawide canvas. It has no value to read back; its answer is logged.
    private func recentreNow() {
        guard steadyHeld, let l = link, !l.closed else {
            plog("settings: the canvas recentre is for Steady mode only; nothing sent")
            return
        }
        guard l.get(ControlWire.ultrawideGet)?.flag == 1 else {
            plog("settings: the glasses are not in Ultrawide; no canvas recentre sent")
            return
        }
        paceSet()
        plog("settings: recentre (10279), the Ultrawide canvas")
        _ = try? l.request("recentre the canvas") { try ControlWire.recenterFrame($0) }
        lastSetAt = Date()
    }

    private static func names(_ steps: [SteadyPlan.Step]) -> String {
        let words: [String] = steps.map { $0.rawValue }
        return words.isEmpty ? "nothing to do" : words.joined(separator: ", ")
    }

    private static func show(_ v: Int?) -> String { v.map { "\($0)" } ?? "not read" }
    private static func show(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "not read" }

    private func restoreGlasses() {
        guard let first = link, !first.closed else { return }
        var changed = false
        if steadyWanted || steadyHeld {
            leaveSteady(quitting: true)
            changed = true
        }
        guard let l = link, !l.closed else { return }
        let st = read()
        if st.stereo == 1 && weSet3D {
            setAndCheck("2D", get: ControlWire.stereoGet, want: 0) { try ControlWire.stereoSetFrame($0, sbs: false) }
            changed = true
        }
        weSet3D = false
        read()
        // Held a moment after a change, as Pocket XR does, so the glasses keep it.
        if changed { Thread.sleep(forTimeInterval: 2) }
    }
}

/// Steady mode's steps as pure functions, ported from Pocket XR's SteadyMode: what to send next from what the glasses
/// last answered. Nothing here touches a link.
public enum SteadyPlan {
    public enum Step: String, Equatable, Sendable {
        /// A setting the step depends on is not read yet.
        case wait
        case anchorOff, anchorOn, leave3D, ultrawideOn, screenMax, ultrawideOff
        /// Putting back what was there before Steady mode (only in [steps], with its `before`).
        case sizeBack, stereoBack
        case done
    }

    /// What the glasses read before Steady mode was entered, so leaving can put it back.
    public struct Before: Equatable, Sendable {
        public var stereo: Int?
        public var ultrawide: Int?
        public var size: Double?
        /// The 3D that was on had been asked for by this app (so it is the app's to ask for again, not the user's).
        public var our3D: Bool

        public init(stereo: Int? = nil, ultrawide: Int? = nil, size: Double? = nil, our3D: Bool = false) {
            self.stereo = stereo
            self.ultrawide = ultrawide
            self.size = size
            self.our3D = our3D
        }
    }

    /// Two screen sizes closer than this are the same.
    public static let sizeSame = 0.005
    /// Ultrawide leaving by itself a second time within this long means the user wants out.
    public static let secondDropS = 30.0
    /// Ultrawide seen off within this long of a new link is the glasses coming back from a re-plug, not their button.
    public static let replugS = 15.0

    public static let turnOn6DoF = "Steady mode in 6DoF: turn on 6DoF in your glasses' menu (Spatial Display) so the screen stays put as you move"
    public static let turnOff6DoF = "Steady mode is off: turn 6DoF off again in your glasses' menu, and use Follow mode with Stabilizer off"

    /// The one thing to do next (SteadyMode.next). Ultrawide can only be turned on from 2D. With [sixDof] the glasses'
    /// Spatial Anchor is turned on last, after Ultrawide and the screen size (each of those re-plugs the display), and
    /// off first on the way out. With [sixDof] on glasses where the user sets 6DoF ([appAnchor] false, the One series
    /// with the Eye) the anchor is neither read nor set.
    public static func next(on: Bool, state g: SettingsControl.State, sixDof: Bool = false, appAnchor: Bool = true) -> Step {
        guard let ultrawide = g.ultrawide else { return .wait }
        if sixDof && !appAnchor {
            if !on { return ultrawide == 1 ? .ultrawideOff : .done }
            guard let stereo = g.stereo else { return .wait }
            if stereo == 1 { return .leave3D }
            if ultrawide != 1 { return .ultrawideOn }
            guard let size = g.sizeFactor, let top = g.sizeMax else { return .wait }
            return size < top - sizeSame ? .screenMax : .done
        }
        if !on {
            if sixDof && g.anchor == 1 { return .anchorOff }
            return ultrawide == 1 ? .ultrawideOff : .done
        }
        guard let anchor = g.anchor else { return .wait }
        guard let stereo = g.stereo else { return .wait }
        if !sixDof && anchor == 1 { return .anchorOff }
        if stereo == 1 { return .leave3D }
        if ultrawide != 1 { return .ultrawideOn }
        guard let size = g.sizeFactor, let top = g.sizeMax else { return .wait }
        if size < top - sizeSame { return .screenMax }
        if sixDof && anchor != 1 { return .anchorOn }
        return .done
    }

    /// The whole change in order, from [state], taking each step as done once sent: for the log and the checks.
    /// SettingsControl itself decides each step afresh from a new reading ([next]). The list ends with `.wait` when
    /// a setting it needs is not read yet. Leaving with [before] adds what is put back: the screen size (sent only if
    /// it then reads different) and 3D that was the user's own.
    public static func steps(entering: Bool, sixDof: Bool, state: SettingsControl.State, appAnchor: Bool = true,
                             before: Before? = nil) -> [Step] {
        var s = state
        var out = [Step]()
        for _ in 0..<12 {
            let step = next(on: entering, state: s, sixDof: sixDof, appAnchor: appAnchor)
            if step == .done { break }
            if step == .wait {
                out.append(.wait)
                return out
            }
            if step == .ultrawideOff, let b = before, b.ultrawide == 1,
               sizeToPutBack(before: b.size, now: s.sizeFactor) != nil {
                out.append(.sizeBack)
                s.sizeFactor = b.size
            }
            out.append(step)
            switch step {
            case .anchorOff: s.anchor = 0
            case .anchorOn: s.anchor = 1
            case .leave3D: s.stereo = 0
            case .ultrawideOn: s.ultrawide = 1
            case .ultrawideOff: s.ultrawide = 0
            case .screenMax: s.sizeFactor = s.sizeMax
            case .wait, .done, .sizeBack, .stereoBack: break
            }
        }
        if !entering, let b = before {
            if b.ultrawide != 1, sizeToPutBack(before: b.size, now: s.sizeFactor) != nil { out.append(.sizeBack) }
            if b.stereo == 1 { out.append(.stereoBack) }
        }
        return out
    }

    /// The screen size to set again when leaving, or nil when it reads as before, or was never read, or cannot be
    /// believed.
    public static func sizeToPutBack(before: Double?, now: Double?) -> Double? {
        guard let old = ControlWire.believableSize(before), let cur = now, cur.isFinite else { return nil }
        return abs(cur - old) > sizeSame ? old : nil
    }

    /// What to do when the glasses leave Ultrawide by themselves in Steady mode (SteadyMode.dropped).
    public enum Dropped: Equatable, Sendable { case backIn, leave, replug }

    public static func dropped(nowS: Double, lastDropS: Double?, linkOpenedS: Double? = nil) -> Dropped {
        if let opened = linkOpenedS, nowS - opened >= 0, nowS - opened < replugS { return .replug }
        if let last = lastDropS, nowS - last >= 0, nowS - last < secondDropS { return .leave }
        return .backIn
    }
}
