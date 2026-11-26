import AppKit
import PocketXRCore
import SwiftUI

// Pocket XR's control panel: the app's home, a small window on the Mac's own screen. From the top: what is plugged
// in, a map of the displays (click a screen to put the pointer on it), a pad that moves and resizes the floating
// screens by hand, the layout, size, distance and curve, 3D and Steady mode. Always dark, in the settings window's
// look; its parts that are its own are in ControlPanelViews.swift.

enum ControlPanelMetrics {
    static let width: CGFloat = 440
    /// The strip the window's buttons sit in, with the app's name beside them.
    static let strip: CGFloat = 30
    static let side: CGFloat = 16
    static let gap: CGFloat = 14
    static let mapHeight: CGFloat = 64
    static let padHeight: CGFloat = 146
    /// The pad shows this many degrees up and down at its largest scale.
    static let padPitchSpan: Double = 68
    static let sliderRow: CGFloat = 34
}

/// Makes and shows the control panel.
@MainActor
final class ControlPanelController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let state: AppState
    private let actionsRef: SettingsActionsRef
    private var window: NSWindow?

    init(store: SettingsStore, state: AppState, actions: AppActions) {
        self.store = store
        self.state = state
        self.actionsRef = SettingsActionsRef(actions)
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Makes the window on first use, in the middle of the Mac's own screen, and brings it to the front. Pocket XR is
    /// a menu bar app, so it has to step forward itself.
    func show() {
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = makeWindow()
            window = w
            w.centre(on: NSScreen.own)
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.keepOnOwnScreen("control panel")
    }

    func keepOnOwnScreen() { window?.keepOnOwnScreen("control panel") }

    /// Closing only hides it; the menu brings it back as it was.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func makeWindow() -> NSWindow {
        let height: CGFloat = fittedHeight(measuredHeight())
        let rect = NSRect(x: 0, y: 0, width: ControlPanelMetrics.width, height: height)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        let w = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        w.title = "Pocket XR"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(
            srgbRed: CGFloat(Look.page.r),
            green: CGFloat(Look.page.g),
            blue: CGFloat(Look.page.b),
            alpha: 1
        )
        w.delegate = self

        let root = ControlPanelRootView(
            store: store,
            state: state,
            actions: actionsRef,
            onHeight: { [weak self] h in self?.fit(contentHeight: h) }
        )
        .ignoresSafeArea()
        let host = NSHostingView(rootView: root)
        // The window keeps the size it is given here; the content does not push it about.
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(rect.size)
        return w
    }

    /// The panel's whole height as its content stands now, before the window exists.
    private func measuredHeight() -> CGFloat {
        let view = ControlPanelRootView(store: store, state: state, actions: SettingsActionsRef(nil))
            .environment(\.settingsStatic, true)
        let probe = NSHostingController(rootView: view)
        let size: CGSize = probe.sizeThatFits(in: CGSize(width: ControlPanelMetrics.width, height: 4000))
        return size.height
    }

    /// As tall as the content, but never taller than the Mac's screen has room for (the content scrolls then).
    private func fittedHeight(_ wanted: CGFloat) -> CGFloat {
        let screen: NSScreen? = window?.screen ?? NSScreen.own
        let room: CGFloat = (screen?.visibleFrame.height ?? 800) - 12
        return min(max(wanted.rounded(.up), 320), max(room, 320))
    }

    /// The content's height changed (floating screens came or went): the window follows, its top edge staying put.
    private func fit(contentHeight: CGFloat) {
        guard let w = window, contentHeight > 1 else { return }
        let target: CGFloat = fittedHeight(contentHeight + ControlPanelMetrics.strip)
        var frame: NSRect = w.frame
        guard abs(frame.height - target) > 0.5 else { return }
        frame.origin.y += frame.height - target
        frame.size.height = target
        w.setFrame(frame, display: true, animate: false)
        w.keepOnOwnScreen("control panel")
    }
}

// MARK: the shell

/// The whole panel: the strip with the app's name, then everything else, scrolling only if the screen is too short.
struct ControlPanelRootView: View {
    let store: SettingsStore
    let state: AppState
    let actions: SettingsActionsRef
    var onHeight: (CGFloat) -> Void = { _ in }
    @Environment(\.settingsStatic) private var isStatic

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ControlPanelStrip(state: state)
            if isStatic {
                column
            } else {
                ScrollView(.vertical) { column.background(measure) }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: ControlPanelMetrics.width)
        .background(Color.lookPage)
        .environment(\.colorScheme, .dark)
    }

    private var measure: some View {
        let report: (CGFloat) -> Void = onHeight
        return GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.height, initial: true) { _, h in report(h) }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: ControlPanelMetrics.gap) {
            ControlPanelStatus(state: state)
                .settingsArrive(0)
            ControlPanelMapCard(store: store, state: state, actions: actions)
                .settingsArrive(1)
            ControlPanelPlaceCard(store: store, state: state, actions: actions)
                .settingsArrive(2)
            ControlPanelSpaceCard(store: store, state: state, actions: actions)
                .settingsArrive(3)
            ControlPanelFooter(actions: actions)
                .settingsArrive(4)
        }
        .padding(.horizontal, ControlPanelMetrics.side)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(width: ControlPanelMetrics.width, alignment: .leading)
    }
}

/// The top strip: the app's name beside the window's buttons, and what the picture is doing now on the right.
struct ControlPanelStrip: View {
    @ObservedObject var state: AppState
    @Environment(\.settingsStatic) private var isStatic

    private var fpsText: String {
        "\(Int(state.fps.rounded())) fps"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            lights
            Text("Pocket XR")
                .font(Font.system(size: 13.5, weight: .medium))
                .foregroundColor(Color.lookInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if state.glassesName != nil {
                Text(fpsText)
                    .font(Font.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundColor(Color.lookInk2)
                    .padding(.trailing, 2)
                SettingsChip("3D", lit: state.stereo)
                SettingsChip("Steady", lit: state.steady)
            }
        }
        .padding(.trailing, ControlPanelMetrics.side)
        .frame(height: ControlPanelMetrics.strip)
        .frame(maxWidth: .infinity)
    }

    /// Room for the window's three buttons; in a picture file, three dim dots stand in for them.
    @ViewBuilder
    private var lights: some View {
        if isStatic {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, 7)
            .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: 72, height: 1)
        }
    }
}

/// The glasses and one line saying where things stand.
struct ControlPanelStatus: View {
    @ObservedObject var state: AppState

    private var title: String {
        state.glassesName ?? "Plug in your glasses"
    }

    /// The status line without what the title already says: it starts with the glasses' name, and with no glasses
    /// it is the title's own words.
    private var line: String? {
        var text: String = state.statusLine
        if let name = state.glassesName, text.hasPrefix(name) {
            text = String(text.dropFirst(name.count))
            while let c = text.first, c == " " || c == "·" { text.removeFirst() }
        }
        let bare: String = text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if bare.isEmpty || bare == title { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var spoken: String {
        var parts = [String]()
        parts.append(state.glassesName ?? "No glasses")
        if let line { parts.append(line) }
        if state.stereo { parts.append("3D") }
        if state.steady { parts.append("Steady mode") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsDot(lit: state.trackingOn)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.system(size: 19, weight: .medium))
                    .foregroundColor(Color.lookInk)
                    .lineLimit(1)
                if let line {
                    Text(line)
                        .font(Font.lookNote)
                        .foregroundColor(Color.lookInk2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status"))
        .accessibilityValue(Text(spoken))
    }
}

// MARK: layout, size, 3D

/// The layout, three sliders, and the two switches.
struct ControlPanelSpaceCard: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef

    private var count: Int {
        max(state.virtualScreens, store.s.screens)
    }

    private var steadyBinding: Binding<Bool> {
        let now: AppState = state
        let ref: SettingsActionsRef = actions
        return Binding(
            get: { now.steady },
            set: { on in ref.target?.setSteady(on) }
        )
    }

    var body: some View {
        SettingsCard {
            if state.steady {
                Text("In Steady mode the glasses show your screens side by side on one flat picture. Change their size here. Turn Steady mode off for 3D, layouts, distance and curve.")
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ControlPanelSliderRow(
                    "Size",
                    value: $store.s.steadyZoom,
                    range: SpaceSettings.steadyZoomRange,
                    step: 0.05,
                    valueText: "\(Int((store.s.steadyZoom * 100).rounded())) %"
                )
                ControlPanelSliderRow(
                    "Screen gap",
                    value: $store.s.steadyGapDeg,
                    range: SpaceSettings.steadyGapRange,
                    step: 0.1,
                    valueText: String(format: "%.1f°", store.s.steadyGapDeg)
                )
                .help("The space between screens in Steady mode.")
            } else {
                // Arrangement, layout, size, distance and curve do nothing in Steady mode, so they are not shown
                // there: the panel stays short enough for a laptop's screen.
                arrangements
                SettingsDivider()
                layout
                SettingsDivider()
                sliders
            }
            SettingsDivider()
            switches
        }
    }

    /// Saved arrangements: pick one to load it, or save the Space as it is now. Renaming is in Settings.
    private var arrangements: some View {
        let saved: [SpacePreset] = store.s.presets
        let current: SpacePreset? = saved.first(where: { store.s.matches($0) })
        return HStack(alignment: .center, spacing: 8) {
            Text("Arrangement")
                .font(Font.lookLine)
                .foregroundColor(Color.lookInk)
            Spacer(minLength: 8)
            ControlPanelArrangementPicker(store: store, actions: actions, title: current?.name ?? (saved.isEmpty ? "Save or load" : "Not saved"))
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var layout: some View {
        let n: Int = count
        return ControlPanelSegmented(
            selection: $store.s.layout,
            values: SpaceLayout.choices(count: n),
            label: "Layout",
            title: { SpaceLayout.title($0, count: n) }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 0) {
            ControlPanelSliderRow(
                "Size",
                value: $store.s.widthDeg,
                range: SpaceSettings.widthRange,
                step: 1,
                valueText: SettingsFormat.degrees(store.s.widthDeg)
            )
            ControlPanelSliderRow(
                "Distance",
                value: $store.s.distance,
                range: SpaceSettings.distanceRange,
                step: 0.1,
                valueText: SettingsFormat.metres(store.s.distance)
            )
            ControlPanelSliderRow(
                "Curve",
                value: $store.s.curve,
                range: SpaceSettings.curveRange,
                step: 0.05,
                valueText: SettingsFormat.curve(store.s.curve)
            )
        }
        .padding(.vertical, 3)
    }

    private var switches: some View {
        HStack(alignment: .center, spacing: 0) {
            // The glasses hold one flat picture in Steady mode (Ultrawide is a 2D mode), so 3D waits until it is off.
            ControlPanelSwitch(title: "3D", isOn: $store.s.want3D, enabled: !state.steady)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 24)
            ControlPanelSwitch(
                title: "Steady mode",
                isOn: steadyBinding,
                enabled: state.steadyAvailable && state.linkOpen
            )
        }
        .frame(height: 44)
    }
}

/// One of the two switches that share a row.
struct ControlPanelSwitch: View {
    let title: String
    @Binding var isOn: Bool
    let enabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(Font.lookLine)
                .foregroundColor(enabled ? Color.lookInk : Color.lookInk3)
                .lineLimit(1)
            Spacer(minLength: 4)
            SettingsToggle(isOn: $isOn, label: title, enabled: enabled)
        }
        .padding(.leading, SettingsMetrics.inset)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity)
    }
}

/// A slider row narrow enough for the panel: the name, the slider, the value in digits that keep their width.
struct ControlPanelSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(Font.lookLine)
                .foregroundColor(Color.lookInk)
                // "Screen gap" is 73 points wide in this font (measured on macOS 14).
                .frame(width: 76, alignment: .leading)
            SettingsSlider(value: $value, range: range, step: step, label: title, valueText: valueText)
            Text(valueText)
                .font(Font.system(size: 13, weight: .regular).monospacedDigit())
                .foregroundColor(Color.lookInk2)
                .lineLimit(1)
                .frame(width: 46, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .frame(height: ControlPanelMetrics.sliderRow)
    }
}

/// The layout picker: the settings window's segmented control, with segments that share the panel's width so four
/// names fit ("Main + two stacked" is the long one).
struct ControlPanelSegmented<T: Hashable>: View {
    @Binding var selection: T
    let values: [T]
    let label: String
    let title: (T) -> String
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<T>, values: [T], label: String, title: @escaping (T) -> String) {
        self._selection = selection
        self.values = values
        self.label = label
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { pair in
                ControlPanelSegment(
                    text: title(pair.element),
                    selected: pair.element == selection,
                    space: space,
                    action: { pick(pair.element) }
                )
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .fill(Color.lookPad)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(Color.lookRim, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }

    private func pick(_ v: T) {
        guard v != selection else { return }
        if reduceMotion {
            selection = v
        } else {
            withAnimation(Animation.lookEnter(0.22)) { selection = v }
        }
    }
}

struct ControlPanelSegment: View {
    let text: String
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(text))
            .accessibilityValue(Text(selected ? "Selected" : ""))
    }

    private var face: some View {
        Text(text)
            .font(Font.system(size: 12.5, weight: selected ? .medium : .regular))
            .foregroundColor(selected ? Color.lookPage : Color.lookInk)
            .lineLimit(1)
            // Never narrower than its words; what width is left over is shared out.
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(highlight)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.lookHeld, lineWidth: 2)
                    .opacity(focused ? 1 : 0)
            )
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var highlight: some View {
        if selected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.lookAccent)
                .matchedGeometryEffect(id: "pick", in: space)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.lookGlassHover)
                .opacity(hover ? 1 : 0)
        }
    }
}

// MARK: footer

/// The quiet buttons at the foot: the settings window, the tour, and leaving.
struct ControlPanelFooter: View {
    let actions: SettingsActionsRef

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // What lives in the glasses: the launcher on a floating screen, the Mac's screen dark, hands.
            HStack(alignment: .center, spacing: 8) {
                SettingsButton("Launcher", symbol: "square.grid.3x3") { actions.target?.toggleLauncher() }
                SettingsButton("Pocket mode", symbol: "lock") { actions.target?.setPocketMode(true) }
                SettingsButton("Hands", symbol: "hand.point.up.left") { actions.target?.setHands(true) }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 8) {
                SettingsButton("Settings…", symbol: "gearshape") { actions.target?.openSettings() }
                SettingsButton("Tour") { actions.target?.openTour() }
                Spacer(minLength: 8)
                SettingsButton("Quit") { actions.target?.quit() }
            }
        }
    }
}


/// The pill that opens the list of saved arrangements: load one, save the Space as it is now, or remove one.
struct ControlPanelArrangementPicker: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActionsRef
    let title: String
    @State private var open: Bool = false
    @State private var hover: Bool = false

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Font.lookLine)
                    .foregroundColor(Color.lookInk)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.lookInk2)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule(style: .continuous).fill(hover ? Color.lookGlassHover : Color.white.opacity(0.05)))
            .overlay(Capsule(style: .continuous).stroke(Color.lookRim, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Text("Saved arrangements: \(title)"))
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        let saved: [SpacePreset] = store.s.presets
        return VStack(alignment: .leading, spacing: 2) {
            if saved.isEmpty {
                Text("Nothing saved yet.")
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ForEach(saved) { p in
                HStack(spacing: 4) {
                    ControlPanelListRow(text: p.name, symbol: store.s.matches(p) ? "checkmark" : nil, strong: false) {
                        var s: SpaceSettings = store.s
                        s.apply(p)
                        store.s = s
                        open = false
                    }
                    Button(action: {
                        var s: SpaceSettings = store.s
                        s.presets.removeAll { $0.id == p.id }
                        store.s = s
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Color.lookInk3)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove \(p.name)"))
                }
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 4)
            ControlPanelListRow(text: "Save this arrangement", symbol: "plus", strong: true) {
                var s: SpaceSettings = store.s
                s.saveArrangement()
                store.s = s
            }
            if !saved.isEmpty {
                ControlPanelListRow(text: "Rename in Settings…", symbol: nil, strong: false) {
                    open = false
                    actions.target?.openSettings()
                }
            }
        }
        .padding(8)
        .frame(width: 250)
        .background(Color.lookCard)
        .environment(\.colorScheme, .dark)
    }
}

/// One row of the arrangements list.
struct ControlPanelListRow: View {
    let text: String
    let symbol: String?
    let strong: Bool
    let action: () -> Void
    @State private var hover: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(text)
                    .font(Font.lookLine)
                    .foregroundColor(strong ? Color.lookHeld : Color.lookInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.lookAccent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Color.lookGlassHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}