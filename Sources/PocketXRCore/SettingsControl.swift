import Foundation

/// The glasses' own settings, kept right for "window in space", as Pocket XR does on the phone and the Deck. Ported
/// from the Deck's settingsctl.py (3DoF only for now; Steady mode in 6DoF comes in phase 2).
///
/// Runs on its own thread. Only commands Pocket XR has proven are sent (ControlWire.sendable), one at a time, at least
/// 3 s apart, each read back (on the Deck a Spatial Anchor set sent within a second of Ultrawide was refused).
///
///   On the Aura:  Spatial Anchor off, Ultrawide off (the app does the head tracking), follow mode, then 3D.
///   Quit:         put back only what this app changed, then wait 2 s.
public final class SettingsControl: @unchecked Sendable {
    public struct State: Equatable, Sendable {
        public var link = false
        public var stereo: Int?
        public var anchor: Int?
        public var ultrawide: Int?
        public var busy = false
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

    private enum Job { case apply, restore(() -> Void) }

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
    /// The app's "3D side by side" setting.
    public var want3D: @Sendable () -> Bool = { true }

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
    public func restore(done: @escaping () -> Void) { enqueue(.restore(done)) }

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
                    keepFollow()
                    keep3D()
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
            }
            state.busy = false
            publish()
        }
    }

    private func open() -> Bool {
        guard let l = try? ControlLink() else {
            if state.link { state.link = false; publish() }
            return false
        }
        link = l
        plog("settings: control link open via \(l.via)")
        followTriesUsed = 0
        sbsTriesUsed = 0
        sbsFirstAt = nil
        read()
        enqueue(.apply)
        return true
    }

    @discardableResult
    private func read() -> State {
        guard let l = link else { return state }
        state.link = !l.closed
        state.stereo = l.get(ControlWire.stereoGet)?.flag
        state.anchor = l.get(ControlWire.anchorGet)?.flag
        state.ultrawide = l.get(ControlWire.ultrawideGet)?.flag
        publish()
        return state
    }

    private func publish() {
        var s = state
        s.link = link.map { !$0.closed } ?? false
        onState(s)
    }

    /// Sets a value, then reads it back until it holds or [setGapS] has passed; tries twice.
    @discardableResult
    private func setAndCheck(_ what: String, get: Int, want: Int, _ build: @escaping (UInt32) throws -> [UInt8]) -> Bool {
        guard let l = link else { return false }
        for attempt in 1...Self.tries {
            plog("settings: \(what) (try \(attempt))")
            _ = try? l.request(what, build)
            let end = Date().addingTimeInterval(Self.setGapS)
            while Date() < end {
                if l.get(get)?.flag == want {
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

    private func applyWindowInSpace() {
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
        guard link != nil else { return }
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
        guard let first = sbsFirstAt, Date().timeIntervalSince(first) <= Self.sbsDropWindowS else { return }
        if sbsTriesUsed < Self.sbsTries && want3D() { depth(fresh: false) }
    }

    /// On the Aura: follow mode, so the glasses do not hold the picture against the app's tracking.
    private func keepFollow() {
        lastFollowCheck = Date()
        guard glasses.managed, let l = link, !l.closed else { return }
        guard followTriesUsed < Self.followTries, state.ultrawide != 1 else { return }
        if l.get(ControlWire.spaceModeGet)?.flag == ControlWire.spaceFollow { return }
        followTriesUsed += 1
        plog("settings: the glasses are in hover; follow mode (try \(followTriesUsed))")
        _ = try? l.request("follow") { try ControlWire.followFrame($0) }
        followSentAt = Date()
        Thread.sleep(forTimeInterval: Self.followReadS)
        if l.get(ControlWire.spaceModeGet)?.flag == ControlWire.spaceFollow {
            plog("settings: follow mode holds")
        } else {
            Thread.sleep(forTimeInterval: max(0, Self.followRetryS - Self.followReadS))
        }
    }

    private func restoreGlasses() {
        guard let l = link, !l.closed else { return }
        let st = read()
        var changed = false
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
