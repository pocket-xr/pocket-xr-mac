import AppKit
import PocketXRCore
import SwiftUI

// The launcher: the Mac's apps on a panel in the glasses. It is an ordinary borderless window shown on a floating
// screen (a virtual display), so it is captured and drawn in the glasses like any other window. From the top: the
// time, the date, the battery and Wi-Fi; a row of round buttons; a search that takes typing at once; the pinned
// apps; pages of every app. Its looks are in LauncherViews.swift, what it reads from the Mac in LauncherApps.swift,
// and its logic that needs no screen in the core's LauncherLogic.swift.

/// The round buttons, in the order shown.
enum LauncherButton: CaseIterable {
    case recentre, steady, depth, pocket, hands, pcScreen, controlPanel, settings

    var title: String {
        switch self {
        case .recentre: return "Recentre"
        case .steady: return "Steady"
        case .depth: return "3D"
        case .pocket: return "Pocket mode"
        case .hands: return "Hands"
        case .pcScreen: return "Other computer"
        case .controlPanel: return "Control panel"
        case .settings: return "Settings"
        }
    }

    /// An SF Symbol; 3D is drawn as its two characters instead.
    var symbol: String {
        switch self {
        case .recentre: return "scope"
        case .steady: return "lock"
        case .depth: return ""
        case .pocket: return "moon"
        case .hands: return "hand.raised"
        case .pcScreen: return "desktopcomputer"
        case .controlPanel: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }

    /// A switch stays lit while it is on, and pressing it leaves the launcher open.
    var staysOpen: Bool {
        self == .steady || self == .depth || self == .hands
    }
}

/// The small menu a right click on an app opens.
struct LauncherMenu: Equatable {
    let app: LauncherApp
    let spot: LauncherSpot
    /// Where it was clicked, in the launcher window's points from its top left.
    let at: CGPoint
    let pinned: Bool
}

/// Why the launcher closes: whether the app that was in front before it gets the keyboard back.
enum LauncherClose {
    /// Escape, a click beside the panel, the shortcut, Recentre: back to the app that was in front.
    case dismissed
    /// An app was opened, another window of Pocket XR was asked for, or the user clicked elsewhere: leave it be.
    case handedOver
}

/// Everything the launcher's views show, and what the keys and the mouse do to it.
@MainActor
final class LauncherModel: ObservableObject {
    let store: SettingsStore
    let state: AppState
    weak var actions: AppActions?
    let icons = LauncherIcons()
    /// A fixed list of made-up apps with drawn icons, for pictures rendered to files.
    let samples: Bool
    var onClose: (LauncherClose) -> Void = { _ in }

    @Published var apps = [LauncherApp]()
    /// The apps have been read once (before that the grid says so instead of looking empty).
    @Published var scanned = false
    @Published private(set) var pins = [LauncherApp]()
    @Published private(set) var query = ""
    /// What the grid shows: every app, or the search's results.
    @Published private(set) var listed = [LauncherApp]()
    @Published var page = 0
    @Published var spot: LauncherSpot?
    @Published var menu: LauncherMenu?
    /// A short line shown in place of the hint for a few seconds.
    @Published private(set) var notice: String?
    /// False while it fades in or out.
    @Published var shown = false
    @Published var layout = LauncherLayout(root: CGSize(width: 1920, height: 1080))
    @Published var now = Date()
    @Published var battery: LauncherBattery?
    @Published var wifi: LauncherWifi?
    var locale = Locale.current

    private var noticeCount = 0
    private var scanning = false
    private var scrollSum: CGFloat = 0
    private var scrollUsed = false
    private var lastWheel: TimeInterval = 0

    init(store: SettingsStore, state: AppState, actions: AppActions?, samples: Bool = false) {
        self.store = store
        self.state = state
        self.actions = actions
        self.samples = samples
        if !samples {
            choosePinsOnce()
            refreshPins()
            rescan()
        }
    }

    // MARK: what is shown

    var searching: Bool { !LauncherSearch.folded(query).isEmpty }

    var grid: LauncherGrid {
        LauncherGrid(
            pins: searching ? 0 : pins.count,
            items: listed.count,
            columns: LauncherMetrics.columns,
            rows: searching ? LauncherMetrics.searchRows : LauncherMetrics.rows
        )
    }

    /// The places in `listed` that are on the page shown.
    var pageRange: Range<Int> {
        LauncherPaging.range(page: page, items: listed.count, perPage: grid.perPage)
    }

    func app(at spot: LauncherSpot) -> LauncherApp? {
        switch spot {
        case .pin(let i): return pins.indices.contains(i) ? pins[i] : nil
        case .item(let i): return listed.indices.contains(i) ? listed[i] : nil
        }
    }

    var timeText: String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: now)
    }

    var dateText: String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: now)
    }

    /// The hint at the bottom, with the launcher's own shortcut when shortcuts are on.
    var hint: String {
        var text: String = "Type to search  ·  Return opens  ·  Esc closes"
        if store.s.shortcuts, let keys = Shortcut.all.first(where: { $0.id == "launcher" })?.keys {
            text += "  ·  \(keys) shows or hides this"
        }
        return text
    }

    // MARK: opening and the Mac's state

    /// Called each time the launcher is shown: a clean start, and the Mac looked at again.
    func prepare() {
        query = ""
        page = 0
        spot = nil
        menu = nil
        notice = nil
        scrollSum = 0
        scrollUsed = false
        relist()
        choosePinsOnce()
        refreshPins()
        refreshStatus()
        rescan()
    }

    func refreshStatus() {
        let date = Date()
        if !Calendar.current.isDate(date, equalTo: now, toGranularity: .minute) { now = date }
        if samples { return }
        let b: LauncherBattery? = LauncherBattery.read()
        if b != battery { battery = b }
        let w: LauncherWifi? = LauncherWifi.read()
        if w != wifi { wifi = w }
    }

    /// The first run: up to four of the Mac's own apps are pinned, and that is remembered so it happens once.
    private func choosePinsOnce() {
        guard !store.s.pinsChosen else { return }
        var s: SpaceSettings = store.s
        if s.pinnedApps.isEmpty {
            s.pinnedApps = LauncherPins.defaults { FileManager.default.fileExists(atPath: $0) }
        }
        s.pinsChosen = true
        store.s = s
    }

    /// The pins to show: those whose app is still there. The setting keeps the others.
    func refreshPins() {
        let paths: [String] = LauncherPins.shown(store.s.pinnedApps, limit: SpaceSettings.maxPinnedApps) { path in
            samples || FileManager.default.fileExists(atPath: path)
        }
        let known: [String: String] = Dictionary(apps.map { ($0.path, $0.name) }, uniquingKeysWith: { a, _ in a })
        let fresh: [LauncherApp] = paths.map { path in
            let fallback: String = samples
                ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                : LauncherApps.name(atPath: path)
            return LauncherApp(path: path, name: known[path] ?? fallback)
        }
        if fresh != pins { pins = fresh }
        if case .pin(let i)? = spot, i >= pins.count { spot = nil }
    }

    /// Reads the apps again off the main thread. What was read last time stays on show meanwhile, so the launcher
    /// opens at once.
    func rescan() {
        guard !samples, !scanning else { return }
        scanning = true
        let own: String = Bundle.main.bundlePath
        Task.detached(priority: .userInitiated) { [weak self] in
            let found: [LauncherApp] = LauncherApps.scan(leavingOut: own)
            await MainActor.run { [weak self] in self?.took(found) }
        }
    }

    private func took(_ found: [LauncherApp]) {
        scanning = false
        let first: Bool = !scanned
        scanned = true
        if found != apps {
            apps = found
            icons.forget(except: Set(found.map(\.path)).union(pins.map(\.path)))
            relist()
            refreshPins()
        }
        if first { plog("launcher: \(found.count) apps found") }
    }

    func setApps(_ list: [LauncherApp]) {
        apps = list
        scanned = true
        relist()
        refreshPins()
    }

    private func relist() {
        let fresh: [LauncherApp]
        if searching {
            fresh = LauncherSearch.results(names: apps.map(\.name), query: query).map { apps[$0] }
        } else {
            fresh = apps
        }
        if fresh != listed { listed = fresh }
        page = LauncherPaging.clamped(page: page, items: listed.count, perPage: grid.perPage)
        if case .item(let i)? = spot, i >= listed.count { spot = listed.isEmpty ? nil : .item(listed.count - 1) }
    }

    // MARK: the keyboard

    /// A key pressed while the launcher has the keyboard. True when the launcher used it.
    func key(_ event: NSEvent) -> Bool {
        let flags: NSEvent.ModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        let code: UInt16 = event.keyCode
        if menu != nil {
            menu = nil
            if code == 53 { return true }
        }
        switch code {
        case 53: escape()
        case 36, 76: openSelected()
        case 51, 117: setQuery(LauncherSearch.erased(query))
        case 123: arrow(.left)
        case 124: arrow(.right)
        case 125: arrow(.down)
        case 126: arrow(.up)
        case 48: break
        default:
            if flags.contains(.control) { return false }
            if let text = event.characters, !text.isEmpty { setQuery(LauncherSearch.typed(query, adding: text)) }
        }
        return true
    }

    /// Escape: closes the menu, else clears the search, else closes the launcher.
    func escape() {
        if menu != nil {
            menu = nil
        } else if !query.isEmpty {
            setQuery("")
        } else {
            onClose(.dismissed)
        }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        page = 0
        relist()
        // A search selects its best result, so Return opens it; with no search nothing is selected until an arrow.
        spot = searching && !listed.isEmpty ? .item(0) : nil
    }

    private func arrow(_ move: LauncherMove) {
        let next = grid.move(spot, move, page: page)
        spot = next.spot
        setPage(next.page)
    }

    private func openSelected() {
        if let spot, let app = app(at: spot) {
            open(app)
        } else if searching, let first = listed.first {
            open(first)
        }
    }

    // MARK: pages

    func setPage(_ wanted: Int) {
        let p: Int = LauncherPaging.clamped(page: wanted, items: listed.count, perPage: grid.perPage)
        guard p != page else { return }
        page = p
        if case .item(let i)? = spot, LauncherPaging.page(ofItem: i, perPage: grid.perPage) != p { spot = nil }
    }

    /// A scroll over the launcher turns the page: one page for a swipe on a trackpad, one for a notch of a wheel.
    func scroll(_ event: NSEvent) {
        if menu != nil { return }
        let dx: CGFloat = event.scrollingDeltaX
        let dy: CGFloat = event.scrollingDeltaY
        let d: CGFloat = abs(dx) > abs(dy) ? dx : dy
        if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) {
                scrollSum = 0
                scrollUsed = false
            }
            // What the fingers did counts; the glide after they lift does not.
            if !event.momentumPhase.isEmpty || scrollUsed { return }
            scrollSum += d
            if abs(scrollSum) > 30 {
                scrollUsed = true
                setPage(page + (scrollSum < 0 ? 1 : -1))
            }
        } else if d != 0, event.timestamp - lastWheel > 0.18 {
            lastWheel = event.timestamp
            setPage(page + (d < 0 ? 1 : -1))
        }
    }

    // MARK: the mouse

    /// A right click or a Control-click at [point] (the window's points from its top left): the menu for the app there.
    func contextClick(at point: CGPoint) {
        let found: LauncherSpot? = layout.spot(at: point, pins: searching ? 0 : pins.count, page: pageRange, searching: searching)
        guard let found, let app = app(at: found) else {
            menu = nil
            return
        }
        menu = LauncherMenu(app: app, spot: found, at: point, pinned: store.s.pinnedApps.contains(app.path))
    }

    /// Opens [app] and closes the launcher.
    func open(_ app: LauncherApp) {
        menu = nil
        if samples { return }
        plog("launcher: opening \(app.name)")
        // The launcher's window is the key window, and it is on a floating screen: that makes that screen the
        // active display, and macOS opens a newly started app's first window on the active display. That is all
        // that steers the app into the glasses; no window is moved for it (that would need Accessibility).
        // An app that is already running only comes to the front, its windows where they were.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let name: String = app.name
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: config) { _, error in
            if let error { plog("launcher: \(name) did not open: \(error.localizedDescription)") }
        }
        onClose(.handedOver)
    }

    func togglePin(_ app: LauncherApp) {
        menu = nil
        var s: SpaceSettings = store.s
        let limit: Int = SpaceSettings.maxPinnedApps
        if s.pinnedApps.contains(app.path) {
            s.pinnedApps = LauncherPins.removing(app.path, from: s.pinnedApps)
        } else {
            var added = LauncherPins.adding(app.path, to: s.pinnedApps, limit: limit)
            if added.result == .full {
                // Pins whose app is gone are not shown; they should not be what makes ten.
                let there: [String] = LauncherPins.shown(s.pinnedApps, limit: limit) { samples || FileManager.default.fileExists(atPath: $0) }
                added = LauncherPins.adding(app.path, to: there, limit: limit)
            }
            if added.result == .full {
                say("Ten apps are pinned. Unpin one first.")
                return
            }
            s.pinnedApps = added.pins
        }
        store.s = s
        refreshPins()
    }

    func showInFinder(_ app: LauncherApp) {
        menu = nil
        if samples { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
        onClose(.handedOver)
    }

    func say(_ line: String) {
        notice = line
        noticeCount += 1
        let mine: Int = noticeCount
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.noticeCount == mine else { return }
            withAnimation(Animation.lookExit()) { self.notice = nil }
        }
    }

    // MARK: the round buttons

    func isLit(_ button: LauncherButton) -> Bool {
        switch button {
        case .steady: return state.steady
        case .depth: return store.s.want3D
        case .pocket: return state.pocketMode
        case .hands: return state.handsRunning
        case .recentre, .pcScreen, .controlPanel, .settings: return false
        }
    }

    func press(_ button: LauncherButton) {
        menu = nil
        if samples { return }
        // The launcher closes first, so a window the button opens is not behind it and takes the keyboard itself.
        switch button {
        case .recentre:
            onClose(.dismissed)
            actions?.recentre()
        case .steady:
            actions?.setSteady(!state.steady)
        case .depth:
            store.s.want3D.toggle()
        case .pocket:
            onClose(.dismissed)
            actions?.setPocketMode(!state.pocketMode)
        case .hands:
            actions?.setHands(!state.handsRunning)
        case .pcScreen:
            // The launcher stays open and says how it goes; it closes once Moonlight starts.
            actions?.openPcScreen()
        case .controlPanel:
            onClose(.handedOver)
            actions?.openControlPanel()
        case .settings:
            onClose(.handedOver)
            actions?.openSettings()
        }
    }
}

/// The launcher's window: borderless and clear, over the whole floating screen (the dimmed backdrop is part of it).
/// It must become key to take typing, so it is a panel that says it can, not a non-activating one. Keys, right
/// clicks and scrolls are taken here, before any view, so typing needs no click and no text field.
final class LauncherPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onContextClick: ((NSPoint) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if onKey?(event) == true { return }
        case .rightMouseDown:
            onContextClick?(event.locationInWindow)
            return
        case .leftMouseDown:
            if event.modifierFlags.contains(.control) {
                onContextClick?(event.locationInWindow)
                return
            }
        case .scrollWheel:
            onScroll?(event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// The launcher: a panel of the Mac's apps shown on a floating screen, so it is seen in the glasses.
@MainActor
final class LauncherController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let state: AppState
    private let model: LauncherModel
    private var panel: LauncherPanel?
    private var open = false
    private var openedAt: TimeInterval = 0
    /// When the launcher last closed because the user went to another window.
    private var leftAt: TimeInterval = -1_000
    private var timer: Timer?
    /// The app that was in front when the launcher opened; it gets the keyboard back if nothing is opened.
    private var before: NSRunningApplication?
    private var closeCount = 0

    init(store: SettingsStore, state: AppState, actions: AppActions) {
        self.store = store
        self.state = state
        self.model = LauncherModel(store: store, state: state, actions: actions)
        super.init()
        model.onClose = { [weak self] why in self?.close(why) }
    }

    var isOpen: Bool { open }

    /// Shows the launcher on [screen] (a floating screen), or hides it when it is open. Open on another screen, it
    /// moves to [screen] instead.
    func toggle(on screen: NSScreen?) {
        // Pressing the control panel's Launcher button first makes the panel the key window, which closes the launcher
        // (the user went elsewhere); the press itself then arrives. It was meant to close the launcher, and it has.
        // Seen in Pocket XR for Windows, 17 Nov 2026: the button closed and at once reopened it.
        if !open, ProcessInfo.processInfo.systemUptime - leftAt < 0.5 { return }
        if open {
            if let screen, let w = panel, w.frame != screen.frame {
                place(w, on: screen)
                w.makeKeyAndOrderFront(nil)
                return
            }
            close(.dismissed)
            return
        }
        guard let screen else {
            plog("launcher: no floating screen to show it on")
            return
        }
        show(on: screen)
    }

    func close() {
        close(.handedOver)
    }

    /// A line under the launcher's buttons for a few seconds (nothing when it is closed).
    func say(_ line: String) {
        if open { model.say(line) }
    }

    private func show(on screen: NSScreen) {
        let w: LauncherPanel = panel ?? makePanel()
        panel = w
        closeCount += 1
        place(w, on: screen)
        model.prepare()
        model.shown = false
        let front: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
        before = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        open = true
        openedAt = ProcessInfo.processInfo.systemUptime
        state.launcherOpen = true
        // Pocket XR is a menu bar app, so it has to step forward itself for its window to take the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        plog("launcher: shown on \(screen.localizedName)")
        let reduce: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task { @MainActor [model] in
            withAnimation(Animation.lookEnter(reduce ? Look.quick : Look.enter)) { model.shown = true }
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.refreshStatus() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer?.invalidate()
        timer = t
    }

    private func close(_ why: LauncherClose) {
        guard open else { return }
        open = false
        state.launcherOpen = false
        timer?.invalidate()
        timer = nil
        model.menu = nil
        withAnimation(Animation.lookExit()) { model.shown = false }
        if why == .dismissed, NSApp.isActive { before?.activate() }
        before = nil
        closeCount += 1
        let mine: Int = closeCount
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Look.exit + 0.03) * 1_000_000_000))
            guard let self, self.closeCount == mine, !self.open else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// Covers [screen] with the window; the panel sits in the middle of what the menu bar and the Dock leave free.
    private func place(_ w: LauncherPanel, on screen: NSScreen) {
        let frame: NSRect = screen.frame
        let free: NSRect = screen.visibleFrame
        w.setFrame(frame, display: true)
        let area = CGRect(
            x: free.minX - frame.minX,
            y: frame.maxY - free.maxY,
            width: free.width,
            height: free.height
        )
        model.layout = LauncherLayout(root: frame.size, area: area)
    }

    private func makePanel() -> LauncherPanel {
        let rect = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let w = LauncherPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        // On every Space and over full-screen apps, and out of Mission Control's and the window menu's way.
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.isMovable = false
        w.animationBehavior = .none
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self

        let host = NSHostingView(rootView: LauncherRootView(model: model).ignoresSafeArea())
        host.sizingOptions = []
        w.contentView = host

        w.onKey = { [weak self] event in self?.model.key(event) ?? false }
        w.onEscape = { [weak self] in self?.model.escape() }
        w.onScroll = { [weak self] event in self?.model.scroll(event) }
        w.onContextClick = { [weak self, weak w] p in
            guard let self, let w else { return }
            // AppKit counts up from the bottom, the views down from the top.
            self.model.contextClick(at: CGPoint(x: p.x, y: w.frame.height - p.y))
        }
        return w
    }

    /// The user clicked another app or another window: the launcher is done. (Just after opening, the keyboard
    /// can pass through other hands while Pocket XR steps forward; that is not the user leaving.)
    func windowDidResignKey(_ notification: Notification) {
        guard open, ProcessInfo.processInfo.systemUptime - openedAt > 0.3 else { return }
        close(.handedOver)
        leftAt = ProcessInfo.processInfo.systemUptime
    }
}
