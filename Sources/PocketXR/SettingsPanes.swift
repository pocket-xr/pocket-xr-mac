import AppKit
import PocketXRCore
import SwiftUI

// The six panes. Each control is bound straight to the settings (`store.s`), so a change is live in the glasses and
// kept at once; what is true now comes from the app's state; anything the app has to do goes through its actions.

// MARK: Space

struct SettingsSpacePane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef

    var body: some View {
        SettingsPaneScaffold(.space) {
            SettingsSpacePreview(store: store, state: state).settingsArrive(1)
            screensCard.settingsArrive(2)
            shapeCard.settingsArrive(3)
            SettingsPresetsCard(store: store).settingsArrive(4)
        }
    }

    private var layoutChoices: [ArrangeLayout] {
        SpaceLayout.choices(count: store.s.screens)
    }

    private var screensCard: some View {
        let count: Int = store.s.screens
        return SettingsCard("Screens") {
            SettingsRow("Screens", note: "Takes effect when Pocket XR opens again.") {
                SettingsSegmented(selection: $store.s.screens, values: [1, 2, 3], label: "Screens") { n in "\(n)" }
            }
            if state.needsRestart {
                SettingsDivider()
                SettingsRow("Open Pocket XR again to use this change.") {
                    SettingsButton("Restart Pocket XR", symbol: "arrow.clockwise", kind: .primary) {
                        actions.target?.restartApp()
                    }
                }
            }
            SettingsDivider()
            SettingsStackedRow("Layout") {
                SettingsSegmented(selection: $store.s.layout, values: layoutChoices, label: "Layout") { layout in
                    SpaceLayout.title(layout, count: count)
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                "Sharper text",
                note: "Gives each screen twice the pixels (HiDPI). Takes effect when Pocket XR opens again.",
                isOn: $store.s.sharperText
            )
            SettingsDivider()
            SettingsRow(
                "Text size",
                note: "Larger text on every screen, the screens as wide as before, so the side screens do not move further out. "
                    + "Each screen gets fewer points (125%: 1536 x 864, 150%: 1280 x 720) and is drawn HiDPI, so it stays sharp. "
                    + "Takes effect when Pocket XR opens again. Readability uses its own size."
            ) {
                SettingsSegmented(selection: $store.s.textScale, values: SpaceSettings.textScales, label: "Text size") { scale in
                    scale == 100 ? "Standard" : "\(scale)%"
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                "Readability",
                note: "Larger, clearer text: one screen at 1440 x 810, \(SettingsFormat.degrees(SpaceSettings.readabilityWidthDeg)) wide. "
                    + "Turning it off puts your screens and size back as they were. Takes effect when Pocket XR opens again. "
                    + "Not yet tried with glasses.",
                isOn: Binding(get: { store.s.readability }, set: { on in store.s.setReadability(on) })
            )
        }
    }

    private var shapeCard: some View {
        SettingsCard("Size and shape") {
            SettingsSliderRow(
                "Size",
                value: $store.s.widthDeg,
                range: SpaceSettings.widthRange,
                step: 1,
                valueText: SettingsFormat.degrees(store.s.widthDeg)
            )
            SettingsDivider()
            SettingsSliderRow(
                "Distance",
                value: $store.s.distance,
                range: SpaceSettings.distanceRange,
                step: 0.1,
                valueText: SettingsFormat.metres(store.s.distance)
            )
            SettingsDivider()
            SettingsSliderRow(
                "Curve",
                value: $store.s.curve,
                range: SpaceSettings.curveRange,
                step: 0.05,
                valueText: SettingsFormat.curve(store.s.curve)
            )
            SettingsDivider()
            SettingsRow("Recentre", note: "Brings the screens in front of where you are looking now.") {
                SettingsButton("Recentre", symbol: "scope", kind: .primary) {
                    actions.target?.recentre()
                }
            }
        }
    }
}

/// The saved arrangements: use one, rename it, delete it, or save the Space as it is now.
struct SettingsPresetsCard: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsCard("Saved arrangements") {
            if store.s.presets.isEmpty {
                SettingsNote("None saved yet. Save the Space as it is now and come back to it with one click, here or from the control panel.")
                SettingsDivider()
            }
            ForEach(store.s.presets) { preset in
                SettingsPresetRow(
                    preset: preset,
                    detail: detail(preset),
                    isCurrent: matches(preset),
                    onApply: { apply(preset) },
                    onRename: { name in rename(preset.id, to: name) },
                    onDelete: { delete(preset.id) }
                )
                SettingsDivider()
            }
            SettingsRow("Save this arrangement", note: currentDetail) {
                SettingsButton("Save", symbol: "plus") { saveCurrent() }
            }
        }
    }

    private var currentDetail: String {
        let s: SpaceSettings = store.s
        return describe(layout: s.layout, widthDeg: s.widthDeg, distance: s.distance, curve: s.curve)
    }

    private func detail(_ p: SpacePreset) -> String {
        describe(layout: p.layout, widthDeg: p.widthDeg, distance: p.distance, curve: p.curve)
    }

    private func describe(layout: ArrangeLayout, widthDeg: Double, distance: Double, curve: Double) -> String {
        let name: String = SpaceLayout.title(layout, count: store.s.screens)
        let size: String = SettingsFormat.degrees(widthDeg)
        let far: String = SettingsFormat.metres(distance)
        let bend: String = curve <= 0.0001 ? "flat" : "curve \(SettingsFormat.curve(curve))"
        return "\(name) · \(size) · \(far) · \(bend)"
    }

    private func matches(_ p: SpacePreset) -> Bool { store.s.matches(p) }

    private func apply(_ p: SpacePreset) {
        var s: SpaceSettings = store.s
        s.apply(p)
        store.s = s
    }
    private func rename(_ id: UUID, to name: String) {
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var s: SpaceSettings = store.s
        guard let i = s.presets.firstIndex(where: { $0.id == id }) else { return }
        s.presets[i].name = trimmed
        store.s = s
    }

    private func delete(_ id: UUID) {
        var s: SpaceSettings = store.s
        s.presets.removeAll { $0.id == id }
        store.s = s
    }

    private func saveCurrent() {
        var s: SpaceSettings = store.s
        s.saveArrangement()
        store.s = s
    }
}

struct SettingsPresetRow: View {
    let preset: SpacePreset
    let detail: String
    let isCurrent: Bool
    let onApply: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @State private var editing: Bool = false
    @State private var draft: String = ""
    @FocusState private var nameFocused: Bool

    init(preset: SpacePreset, detail: String, isCurrent: Bool, onApply: @escaping () -> Void,
         onRename: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.preset = preset
        self.detail = detail
        self.isCurrent = isCurrent
        self.onApply = onApply
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if editing {
                nameField
                SettingsButton("Done", kind: .primary) { finish() }
            } else {
                SettingsRowText(title: preset.name, note: detail)
                Spacer(minLength: 12)
                if isCurrent { SettingsChip("In use", lit: true) }
                SettingsButton("Use", enabled: !isCurrent) { onApply() }
                SettingsIconButton(symbol: "pencil", label: "Rename \(preset.name)") { begin() }
                SettingsIconButton(symbol: "trash", label: "Delete \(preset.name)") { onDelete() }
            }
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, 8)
        .frame(minHeight: SettingsMetrics.row)
    }

    private var nameField: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(Font.lookLine)
            .foregroundColor(Color.lookInk)
            .padding(.horizontal, 10)
            .frame(height: SettingsMetrics.button)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .fill(Color.lookPad)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .strokeBorder(Color.lookAccent, lineWidth: 1.5)
            )
            .focused($nameFocused)
            .onSubmit { finish() }
            .accessibilityLabel(Text("Arrangement name"))
    }

    private func begin() {
        draft = preset.name
        editing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finish() {
        onRename(draft)
        editing = false
    }
}

// MARK: Picture

struct SettingsPicturePane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState

    var body: some View {
        SettingsPaneScaffold(.picture) {
            depthCard.settingsArrive(1)
            lightCard.settingsArrive(2)
        }
    }

    private var depthNote: String {
        if state.glassesName == nil {
            return "Each eye gets its own picture, so the screens sit at a depth."
        }
        return state.stereo ? "The glasses are in 3D now." : "The glasses are in 2D now."
    }

    private var depthCard: some View {
        SettingsCard("3D") {
            SettingsRow("3D side by side", note: depthNote) {
                HStack(alignment: .center, spacing: 10) {
                    if state.glassesName != nil {
                        SettingsChip(state.stereo ? "3D" : "2D", lit: state.stereo)
                    }
                    SettingsToggle(isOn: $store.s.want3D, label: "3D side by side")
                }
            }
            if let note = state.stereoNote {
                SettingsNote(note, warn: true)
            }
            SettingsDivider()
            SettingsSliderRow(
                "Eye distance",
                value: $store.s.ipdMm,
                range: SpaceSettings.ipdRange,
                step: 0.5,
                valueText: String(format: "%.1f mm", store.s.ipdMm)
            )
        }
    }

    private var lightCard: some View {
        SettingsCard("Light") {
            SettingsSliderRow(
                "Brightness",
                value: $store.s.brightness,
                range: SpaceSettings.brightnessRange,
                step: 0.01,
                valueText: SettingsFormat.percent(store.s.brightness)
            )
            SettingsDivider()
            SettingsSliderRow(
                "Window glow",
                value: $store.s.glow,
                range: 0.0...1.0,
                step: 0.05,
                valueText: SettingsFormat.glow(store.s.glow)
            )
            SettingsDivider()
            SettingsRow("Glow colour", note: "The outline of the screen you are looking at.") {
                SettingsGlowSwatches(selection: $store.s.glowColor)
            }
            SettingsDivider()
            SettingsRow("Edge fade", note: "A fade to black at the edges of what you see, so screens do not end at a hard line.") {
                SettingsSegmented(selection: $store.s.edgeFade, values: EdgeFade.allCases, label: "Edge fade") { fade in
                    fade.title
                }
            }
        }
    }
}

struct SettingsGlowSwatches: View {
    @Binding var selection: GlowColor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GlowColor.allCases, id: \.rawValue) { glow in
                SettingsSwatch(
                    color: glow.color.color,
                    name: glow.title,
                    selected: glow == selection,
                    action: { selection = glow }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Glow colour"))
    }
}

// MARK: Head tracking

struct SettingsTrackingPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState

    var body: some View {
        SettingsPaneScaffold(.tracking) {
            mainCard.settingsArrive(1)
            SettingsTrackingNow(state: state).settingsArrive(2)
            advancedCard.settingsArrive(3)
        }
    }

    private var mainCard: some View {
        SettingsCard {
            SettingsToggleRow(
                "Head tracking",
                note: "The screens hold their place as you turn your head.",
                isOn: $store.s.headTracking
            )
            SettingsDivider()
            SettingsRow("Tracking mode", note: store.s.trackingMode.detail) {
                SettingsSegmented(selection: $store.s.trackingMode, values: TrackingMode.allCases, label: "Tracking mode") { mode in
                    mode.title
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                "Recentre follows head tilt",
                note: "Recentre with your head more than 15 degrees up or down puts the screens where you look.",
                isOn: $store.s.recentreFollowsTilt
            )
            SettingsDivider()
            SettingsToggleRow(
                "Head scroll",
                note: "Turn your head a little past the screen in front and the row slides that way. Works in Smooth Follow and in Steady mode, not in Body Anchor, where the screens already stay put.",
                isOn: $store.s.headScroll
            )
            SettingsDivider()
            SettingsToggleRow(
                "Pointer follows head",
                note: "The pointer jumps to the screen you look at when it is on another screen.",
                isOn: $store.s.pointerFollowsHead
            )
            SettingsDivider()
            SettingsToggleRow(
                "Taps on the glasses",
                note: "Tap the glasses' frame twice to recentre, three times to switch the view: Steady mode on or off where your glasses have it, else Body Anchor and Smooth Follow in turn. Up to about 2 taps a second. Needs head tracking. Tap sensitivity: higher for softer taps, lower if it acts when you did not tap. Not yet tried on a Mac with glasses: the log says what each jolt was, so send logs if it misses.",
                isOn: $store.s.glassesTaps
            )
            SettingsSliderRow(
                "Tap sensitivity",
                value: $store.s.tapSensitivity,
                range: GlassesTaps.sensitivityRange,
                step: 5,
                valueText: "\(Int(store.s.tapSensitivity.rounded()))%"
            )
        }
    }

    private var advancedCard: some View {
        SettingsCard("Advanced") {
            SettingsToggleRow(
                "Draw smoothing",
                note: "Evens out the head's movement from one frame to the next.",
                isOn: $store.s.drawSmoothing
            )
            SettingsDivider()
            SettingsToggleRow(
                "Still lock",
                note: "Holds the screens exactly still while your head is still.",
                isOn: $store.s.stillLock
            )
            SettingsDivider()
            SettingsSliderRow(
                "Glasses display delay",
                value: $store.s.displayDelayMs,
                range: SpaceSettings.delayRange,
                step: 1,
                valueText: SettingsFormat.milliseconds(store.s.displayDelayMs)
            )
            SettingsNote("How far ahead Pocket XR works out where your head will be, to make up for the time the glasses take to show a frame.")
        }
    }
}

/// What the head tracking is doing now.
struct SettingsTrackingNow: View {
    @ObservedObject var state: AppState

    private var biasText: String {
        if !state.trackingOn { return "Waiting" }
        return state.biasReady ? "Learnt" : "Learning"
    }

    var body: some View {
        SettingsCard("Now") {
            HStack(alignment: .center, spacing: 20) {
                SettingsHeadGauge(yawDeg: state.yawDeg, pitchDeg: state.pitchDeg, live: state.trackingOn)
                readings
                Spacer(minLength: 0)
            }
            .padding(SettingsMetrics.inset)
            if !state.trackingOn {
                SettingsDivider()
                SettingsNote("No head tracking reports are arriving.")
            } else if !state.biasReady {
                SettingsDivider()
                SettingsNote("Keep your head still for two seconds so Pocket XR can learn the glasses' drift.")
            }
        }
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                SettingsReading(title: "Turn", value: SettingsFormat.signedDegrees(state.yawDeg))
                SettingsReading(title: "Tilt", value: SettingsFormat.signedDegrees(state.pitchDeg))
                SettingsReading(title: "Drift", value: biasText)
            }
            HStack(alignment: .top, spacing: 20) {
                SettingsReading(title: "Reports a second", value: "\(state.imuHz)")
                SettingsReading(title: "Frames a second", value: "\(Int(state.fps.rounded()))")
            }
        }
    }
}

// MARK: Glasses

struct SettingsGlassesPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef

    var body: some View {
        SettingsPaneScaffold(.glasses) {
            connectedCard.settingsArrive(1)
            steadyCard.settingsArrive(2)
            recordingCard.settingsArrive(3)
            experimentalCard.settingsArrive(4)
            SettingsSupportCard().settingsArrive(5)
            toolsCard.settingsArrive(6)
        }
    }

    private var connectedNote: String {
        if state.glassesName == nil { return "Plug in your glasses." }
        if state.busy { return "Changing the glasses' settings…" }
        return state.displayText ?? "Waiting for the glasses' display."
    }

    private var connectedCard: some View {
        SettingsCard("Connected") {
            SettingsRow(state.glassesName ?? "No glasses", note: connectedNote) {
                HStack(alignment: .center, spacing: 6) {
                    if state.glassesName != nil {
                        SettingsChip(state.linkOpen ? "Settings link open" : "No settings link", lit: state.linkOpen)
                        SettingsChip(state.trackingOn ? "Head tracking on" : "No head tracking", lit: state.trackingOn)
                    }
                }
            }
        }
    }

    private var steadyBinding: Binding<Bool> {
        let ref: SettingsActionsRef = actions
        let current: AppState = state
        // Controls only ever call these on the main thread.
        return Binding<Bool>(
            get: {
                MainActor.assumeIsolated { current.steady }
            },
            set: { on in
                MainActor.assumeIsolated {
                    if let target = ref.target { target.setSteady(on) }
                }
            }
        )
    }

    private var steadyCard: some View {
        SettingsCard("Steady mode") {
            SettingsToggleRow(
                "Steady mode",
                note: "For reading and working: the glasses hold the picture completely still themselves. Works with the Aura; the One series is not tried on a Mac yet.",
                isOn: steadyBinding,
                enabled: state.steadyAvailable
            )
            if !state.steadyAvailable {
                SettingsNote(
                    state.glassesName == nil
                        ? "Steady mode needs glasses that can hold the picture themselves. None are plugged in."
                        : "These glasses cannot do Steady mode, or their settings link is not open yet.",
                    warn: state.glassesName != nil
                )
            }
            SettingsDivider()
            SettingsToggleRow(
                "Steady mode in 6DoF",
                note: "Uses the glasses' Spatial Anchor where they have it, so the picture also stays put when you lean or move.",
                isOn: $store.s.steadySixDof
            )
        }
    }

    private var recordingNote: String {
        state.screenRecordingAllowed
            ? "Allowed. Pocket XR can show your screens in the glasses."
            : "Not allowed yet. Pocket XR needs it to show your screens in the glasses."
    }

    private var recordingCard: some View {
        SettingsCard("Permission") {
            SettingsRow("Screen Recording", note: recordingNote) {
                HStack(alignment: .center, spacing: 8) {
                    if state.screenRecordingAllowed {
                        SettingsChip("Allowed", lit: true)
                    } else {
                        SettingsButton("Allow", kind: .primary) { actions.target?.requestScreenRecording() }
                    }
                    SettingsButton("Open System Settings") { actions.target?.openScreenRecordingSettings() }
                }
            }
        }
    }

    private var experimentalCard: some View {
        SettingsCard("Experimental") {
            SettingsToggleRow(
                "Head tracking for XREAL Air and VITURE (USB HID)",
                note: "Untested on a Mac. macOS may ask you to allow Input Monitoring.",
                isOn: $store.s.hidTracking
            )
        }
    }

    private var toolsCard: some View {
        SettingsCard("Tools") {
            SettingsRow("Glasses report", note: "Saves what Pocket XR knows about your glasses to a file, to send when something is wrong.") {
                SettingsButton("Save a Glasses report", symbol: "doc.text") { actions.target?.saveGlassesReport() }
            }
            SettingsDivider()
            SettingsRow("Displays", note: "Where macOS places your virtual screens.") {
                SettingsButton("Open Displays settings", symbol: "display") { actions.target?.openDisplaySettings() }
            }
        }
    }
}

/// Which glasses do what on a Mac, said exactly: only the Aura has been run on one.
struct SettingsSupportCard: View {
    var body: some View {
        SettingsCard("Which glasses work") {
            SettingsRow("XREAL Aura", note: "Works on a Mac: 3D and head tracking.") {
                SettingsChip("Works", lit: true)
            }
            SettingsDivider()
            SettingsRow("XREAL One, One Pro, One Pro+, 1S", note: "The same head tracking as the Aura. The 1S reported working on an M4 Pro Mac; the others not tried on a Mac yet.") {
                SettingsChip("Not tried yet")
            }
            SettingsDivider()
            SettingsRow("XREAL Air family and VITURE", note: "Head tracking with the experimental switch above. Untested on a Mac.") {
                SettingsChip("Experimental")
            }
            SettingsDivider()
            SettingsRow("Other glasses", note: "Screens shown without head tracking.") {
                SettingsChip("Screens only")
            }
        }
    }
}

// MARK: Shortcuts

struct SettingsShortcutsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef
    /// The shortcut whose new keys are being waited for.
    @State private var recording: String? = nil
    /// What was said about a shortcut's last change (it was refused, and why), by id.
    @State private var said: [String: String] = [:]
    @State private var monitor: Any? = nil

    var body: some View {
        SettingsPaneScaffold(.shortcuts) {
            switchCard.settingsArrive(1)
            listCard.settingsArrive(2)
        }
        .onDisappear { stopRecording() }
    }

    private var switchCard: some View {
        SettingsCard {
            SettingsToggleRow(
                "Keyboard shortcuts",
                note: "They work in any app while Pocket XR is open.",
                isOn: $store.s.shortcuts
            )
            SettingsToggleRow(
                "Move and resize with the pointer",
                note: "Hold Control and Option: moving the pointer carries the screens with it, scrolling makes them larger or smaller.",
                isOn: $store.s.grabKeys
            )
            SettingsToggleRow(
                "Open the control panel when Pocket XR starts",
                note: "It is always in the menu bar, under the glasses icon.",
                isOn: $store.s.panelAtStart
            )
        }
    }

    private var listCard: some View {
        // Read so the list is drawn again when a shortcut's keys change.
        let version: Int = state.shortcutsVersion
        let all: [Shortcut] = Shortcut.all
        let anyChosen: Bool = ShortcutChoices.anyChosen
        return SettingsCard("Shortcuts") {
            ForEach(all) { shortcut in
                shortcutRow(shortcut)
                if shortcut.id != all.last?.id || anyChosen { SettingsDivider() }
            }
            if anyChosen {
                SettingsRow("Changed keys") {
                    SettingsButton("Use the usual keys for all", symbol: "arrow.uturn.backward") {
                        said = [:]
                        actions.target?.resetShortcut(nil)
                    }
                }
            }
        }
        .id(version)
        .opacity(store.s.shortcuts ? 1 : 0.45)
        .animation(Animation.lookEnter(), value: store.s.shortcuts)
    }

    private func shortcutRow(_ shortcut: Shortcut) -> some View {
        let listening: Bool = recording == shortcut.id
        var note: String? = nil
        var warn: Bool = false
        if listening {
            note = said[shortcut.id] ?? "With Control, Option or Command. Esc cancels."
            warn = said[shortcut.id] != nil
        } else if let text = said[shortcut.id] {
            note = text
            warn = true
        } else if state.shortcutsTaken.contains(shortcut.id) {
            note = "macOS would not give Pocket XR these keys, so this one does not work."
            warn = true
        }
        return SettingsShortcutRowLayout(title: shortcut.title, note: note, warn: warn) {
            HStack(spacing: 8) {
                if listening {
                    Text("Press the new keys…")
                        .font(Font.lookLine)
                        .foregroundColor(Color.lookHeld)
                } else {
                    SettingsKeys(keys: shortcut.keys)
                }
                SettingsButton(listening ? "Cancel" : "Change") {
                    if listening { stopRecording() } else { startRecording(shortcut.id) }
                }
                if shortcut.changed && !listening {
                    SettingsIconButton(symbol: "arrow.uturn.backward", label: "Use \(shortcut.usualKeys) again") {
                        said[shortcut.id] = nil
                        actions.target?.resetShortcut(shortcut.id)
                    }
                }
            }
        }
    }

    /// Waits for the next keys pressed in this window. Pocket XR lets go of its own shortcuts meanwhile, so they can
    /// be pressed here too (macOS would hand them to Pocket XR's shortcuts first).
    private func startRecording(_ id: String) {
        stopRecording()
        said[id] = nil
        recording = id
        actions.target?.pauseShortcuts(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            take(event, for: id)
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording != nil {
            recording = nil
            actions.target?.pauseShortcuts(false)
        }
    }

    /// One key press while waiting: Esc cancels, a key with Control, Option or Command is taken. Returns nil, so the
    /// press goes no further.
    private func take(_ event: NSEvent, for id: String) -> NSEvent? {
        if event.keyCode == 53 {
            stopRecording()
            return nil
        }
        let flags: NSEvent.ModifierFlags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= Shortcut.control }
        if flags.contains(.option) { mods |= Shortcut.option }
        if flags.contains(.shift) { mods |= Shortcut.shift }
        if flags.contains(.command) { mods |= Shortcut.command }
        let label: String = ShortcutKeyName.symbols(mods) + ShortcutKeyName.name(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        guard mods & (Shortcut.control | Shortcut.option | Shortcut.command) != 0 else {
            said[id] = "\(label) on its own would stop that key typing. Add Control, Option or Command. Esc cancels."
            return nil
        }
        stopRecording()
        if let why = actions.target?.changeShortcut(id: id, keyCode: UInt32(event.keyCode), modifiers: mods, label: label) {
            said[id] = why
        }
        return nil
    }
}

/// A settings row whose note can be a warning (amber), with its control on the right. The same sizes as SettingsRow.
struct SettingsShortcutRowLayout<Trailing: View>: View {
    let title: String
    let note: String?
    let warn: Bool
    let trailing: Trailing

    init(title: String, note: String?, warn: Bool, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.note = note
        self.warn = warn
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.lookLine)
                    .foregroundColor(Color.lookInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(Font.lookNote)
                        .foregroundColor(warn ? Color.lookWarn : Color.lookInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, note == nil ? 6 : 10)
        .frame(minHeight: SettingsMetrics.row)
    }
}

// MARK: Help

struct SettingsHelpPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef
    @State private var confirmingReset: Bool = false

    var body: some View {
        SettingsPaneScaffold(.help) {
            helpCard.settingsArrive(1)
            fileCard.settingsArrive(2)
            appCard.settingsArrive(3)
        }
    }

    private var helpCard: some View {
        SettingsCard {
            SettingsRow("Tour of Pocket XR", note: "Two minutes: setup, your screens, Recentre, 3D and Steady mode") {
                SettingsButton("Open the tour", symbol: "play.fill", kind: .primary) { actions.target?.openTour() }
            }
            SettingsDivider()
            SettingsRow("Send logs to Mike", note: "Makes a zip of the log, with emails, Wi-Fi names and other addresses taken out, and opens an email.") {
                SettingsButton("Send logs", symbol: "paperplane") { actions.target?.sendLogs() }
            }
        }
    }

    private var fileCard: some View {
        SettingsCard("Your settings") {
            SettingsRow("Save settings to a file") {
                SettingsButton("Save…", symbol: "square.and.arrow.down") { actions.target?.exportSettings() }
            }
            SettingsDivider()
            SettingsRow("Restore settings from a file") {
                SettingsButton("Restore…", symbol: "square.and.arrow.up") { actions.target?.importSettings() }
            }
            SettingsDivider()
            resetRow
        }
    }

    private var resetRow: some View {
        SettingsRow(
            "Reset to defaults",
            note: confirmingReset ? "Every setting goes back to how it came, saved arrangements included. This cannot be undone." : nil
        ) {
            HStack(alignment: .center, spacing: 8) {
                if confirmingReset {
                    SettingsButton("Cancel") { setConfirming(false) }
                    SettingsButton("Reset everything", kind: .danger) {
                        store.reset()
                        setConfirming(false)
                    }
                } else {
                    SettingsButton("Reset…", kind: .danger) { setConfirming(true) }
                }
            }
        }
    }

    private func setConfirming(_ on: Bool) {
        withAnimation(Animation.lookEnter(Look.quick)) { confirmingReset = on }
    }

    private var appCard: some View {
        SettingsCard("Pocket XR") {
            SettingsToggleRow(
                "Open at login",
                note: "Pocket XR waits in the menu bar for your glasses.",
                isOn: $store.s.launchAtLogin
            )
            SettingsDivider()
            SettingsToggleRow(
                "Stay awake on the power adapter",
                note: "So your phone can reach this Mac from anywhere, over Tailscale or the like, without waking it. While plugged in, this Mac does not sleep when left idle; its screen still can. Uses some power. Closing a MacBook's lid still sleeps it, unless a display is connected. On battery it sleeps as usual.",
                isOn: $store.s.stayAwakeOnAdapter
            )
            SettingsDivider()
            SettingsRow("Version", note: "Free and open source, GPL-3.0.") {
                Text(state.version)
                    .font(Font.system(size: 14, weight: .regular).monospacedDigit())
                    .foregroundColor(Color.lookInk2)
                    .textSelection(.enabled)
            }
            SettingsDivider()
            SettingsRow("Quit", note: "Gives the glasses back the settings Pocket XR changed, then closes.") {
                SettingsButton("Quit and put the glasses back", symbol: "power") { actions.target?.quit() }
            }
        }
    }
}
