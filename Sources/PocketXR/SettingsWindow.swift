import AppKit
import PocketXRCore
import SwiftUI

// Pocket XR's main window: a sidebar with the six panes and a live status block, and the chosen pane on the right.
// Always dark, whatever the Mac's appearance is.

/// The panes of the settings window.
enum SettingsPane: String, CaseIterable {
    case space, picture, tracking, glasses, hands, controls, shortcuts, help

    var title: String {
        switch self {
        case .space: return "Space"
        case .picture: return "Picture"
        case .tracking: return "Head tracking"
        case .glasses: return "Glasses"
        case .hands: return "Hands"
        case .controls: return "Controls"
        case .shortcuts: return "Shortcuts"
        case .help: return "Help"
        }
    }

    /// What the pane is for, under its title.
    var subtitle: String {
        switch self {
        case .space: return "Where your screens float, how large and how far."
        case .picture: return "3D, brightness and the light around the screen you look at."
        case .tracking: return "How the screens stay put as you turn your head."
        case .glasses: return "What is plugged in and what Pocket XR can do with it."
        case .hands: return "Point and pinch in the air, seen by your glasses' camera."
        case .controls: return "A game controller as a remote for the Space, and Pocket mode."
        case .shortcuts: return "Change the Space from the keyboard, in any app."
        case .help: return "The tour, logs, your settings as a file, and the app itself."
        }
    }

    /// An SF Symbol for the sidebar.
    var symbol: String {
        switch self {
        case .space: return "rectangle.3.group"
        case .picture: return "sun.max"
        case .tracking: return "gyroscope"
        case .glasses: return "eyeglasses"
        case .hands: return "hand.point.up.left"
        case .controls: return "gamecontroller"
        case .shortcuts: return "keyboard"
        case .help: return "questionmark.circle"
        }
    }
}

/// Which pane is showing.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane = .space
}

/// The app's actions, held weakly so the window never keeps the controller alive (and nil while pictures are drawn).
@MainActor
final class SettingsActionsRef {
    weak var target: AppActions?

    init(_ target: AppActions?) {
        self.target = target
    }
}

/// Makes and shows the settings window.
@MainActor
final class SettingsWindowController {
    private let store: SettingsStore
    private let state: AppState
    private let actionsRef: SettingsActionsRef
    private let navigation: SettingsNavigation
    private var window: NSWindow?

    static let defaultSize = NSSize(width: 880, height: 620)
    static let minimumSize = NSSize(width: 760, height: 540)

    init(store: SettingsStore, state: AppState, actions: AppActions) {
        self.store = store
        self.state = state
        self.actionsRef = SettingsActionsRef(actions)
        self.navigation = SettingsNavigation()
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Makes the window on first use and brings it to the front. Pocket XR is a menu bar app, so it has to step
    /// forward itself.
    func show(pane: SettingsPane = .space) {
        navigation.pane = pane
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = makeWindow()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.keepOnOwnScreen("settings")
    }

    func keepOnOwnScreen() { window?.keepOnOwnScreen("settings") }

    private func makeWindow() -> NSWindow {
        let rect = NSRect(origin: .zero, size: Self.defaultSize)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let w = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        w.title = "Pocket XR"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(
            srgbRed: CGFloat(Look.page.r),
            green: CGFloat(Look.page.g),
            blue: CGFloat(Look.page.b),
            alpha: 1
        )
        w.contentMinSize = Self.minimumSize

        let root = SettingsRootView(store: store, state: state, navigation: navigation, actions: actionsRef)
            .ignoresSafeArea()
        let host = NSHostingView(rootView: root)
        // The window keeps its own size; the content does not push it about.
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(Self.defaultSize)
        w.centre(on: NSScreen.own)
        w.setFrameAutosaveName("PocketXRSettingsWindow")
        return w
    }
}

// MARK: the shell

/// The whole window: the sidebar, a hairline, the pane.
struct SettingsRootView: View {
    let store: SettingsStore
    let state: AppState
    let navigation: SettingsNavigation
    let actions: SettingsActionsRef

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(state: state, navigation: navigation)
            Rectangle()
                .fill(Color.lookRim)
                .frame(width: 1)
            SettingsPaneHost(store: store, state: state, navigation: navigation, actions: actions)
        }
        .background(Color.lookPage)
        .environment(\.colorScheme, .dark)
    }
}

/// The left side: the app's name, the panes, and what is happening now.
struct SettingsSidebar: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigation
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState, navigation: SettingsNavigation) {
        self.state = state
        self.navigation = navigation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            name
            list
            Spacer(minLength: 16)
            SettingsStatusBlock(state: state)
        }
        .padding(.horizontal, 10)
        .padding(.top, 50)
        .padding(.bottom, 12)
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Look.pad.color)
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Pocket XR")
                .font(Font.system(size: 17, weight: .medium))
                .foregroundColor(Color.lookInk)
            Text("for Mac")
                .font(Font.lookNote)
                .foregroundColor(Color.lookInk3)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 18)
        .accessibilityElement(children: .combine)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases, id: \.rawValue) { pane in
                SettingsSidebarRow(
                    pane: pane,
                    selected: navigation.pane == pane,
                    space: space,
                    action: { choose(pane) }
                )
            }
        }
    }

    private func choose(_ pane: SettingsPane) {
        guard navigation.pane != pane else { return }
        if reduceMotion {
            navigation.pane = pane
        } else {
            withAnimation(Animation.lookEnter()) { navigation.pane = pane }
        }
    }
}

struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    init(pane: SettingsPane, selected: Bool, space: Namespace.ID, action: @escaping () -> Void) {
        self.pane = pane
        self.selected = selected
        self.space = space
        self.action = action
    }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(pane.title))
            .accessibilityValue(Text(selected ? "Selected" : ""))
    }

    private var face: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: pane.symbol)
                .font(Font.system(size: 13, weight: .regular))
                .foregroundColor(selected ? Color.lookHeld : Color.lookInk2)
                .frame(width: 20, alignment: .center)
            Text(pane.title)
                .font(Font.system(size: 14, weight: selected ? .medium : .regular))
                .foregroundColor(selected ? Color.lookInk : Color.lookInk2)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(Color.lookAccent, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var highlight: some View {
        if selected {
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .fill(Color.lookAccent.opacity(0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                        .strokeBorder(Color.lookAccent.opacity(0.45), lineWidth: 1)
                )
                .matchedGeometryEffect(id: "pane", in: space)
        } else {
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .fill(Color.lookGlassHover)
                .opacity(hover ? 0.7 : 0)
        }
    }
}

/// What is true now, small, at the foot of the sidebar: the glasses, a dot that lights while the head is tracked,
/// frames a second, and whether the picture is 3D or Steady.
struct SettingsStatusBlock: View {
    @ObservedObject var state: AppState

    private var fpsText: String {
        "\(Int(state.fps.rounded())) fps"
    }

    private var spoken: String {
        var parts = [String]()
        parts.append(state.glassesName ?? "No glasses")
        parts.append(state.trackingOn ? "head tracking on" : "head tracking off")
        if state.glassesName != nil { parts.append(fpsText) }
        if state.stereo { parts.append("3D") }
        if state.steady { parts.append("Steady mode") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                SettingsDot(lit: state.trackingOn)
                Text(state.glassesName ?? "No glasses")
                    .font(Font.system(size: 13, weight: .medium))
                    .foregroundColor(state.glassesName == nil ? Color.lookInk2 : Color.lookInk)
                    .lineLimit(1)
            }
            details
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2, style: .continuous)
                .fill(Color.lookCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2, style: .continuous)
                .strokeBorder(Color.lookRim, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status"))
        .accessibilityValue(Text(spoken))
    }

    @ViewBuilder
    private var details: some View {
        if state.glassesName == nil {
            Text("Plug in your glasses.")
                .font(Font.lookChip)
                .foregroundColor(Color.lookInk3)
        } else {
            HStack(alignment: .center, spacing: 5) {
                Text(fpsText)
                    .font(Font.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundColor(Color.lookInk2)
                    .frame(minWidth: 40, alignment: .leading)
                SettingsChip("3D", lit: state.stereo)
                SettingsChip("Steady", lit: state.steady)
            }
        }
    }
}

/// The right side: the chosen pane. A new pane is a new view, so its cards arrive afresh.
struct SettingsPaneHost: View {
    let store: SettingsStore
    let state: AppState
    @ObservedObject var navigation: SettingsNavigation
    let actions: SettingsActionsRef

    var body: some View {
        pane
            .id(navigation.pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.lookPage)
    }

    @ViewBuilder
    private var pane: some View {
        switch navigation.pane {
        case .space: SettingsSpacePane(store: store, state: state, actions: actions)
        case .picture: SettingsPicturePane(store: store, state: state)
        case .tracking: SettingsTrackingPane(store: store, state: state)
        case .glasses: SettingsGlassesPane(store: store, state: state, actions: actions)
        case .hands: SettingsPaneScaffold(.hands) { HandsSettingsSection(store: store, state: state, actions: actions) }
        case .controls: SettingsPaneScaffold(.controls) { ControllerSettingsSection(store: store, state: state, actions: actions).settingsArrive(1) }
        case .shortcuts: SettingsShortcutsPane(store: store, state: state, actions: actions)
        case .help: SettingsHelpPane(store: store, state: state, actions: actions)
        }
    }
}

/// A pane's frame: its large title, a line under it, then its cards, scrolling when the window is short.
struct SettingsPaneScaffold<Content: View>: View {
    let pane: SettingsPane
    let content: Content
    @Environment(\.settingsStatic) private var isStatic

    init(_ pane: SettingsPane, @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.content = content()
    }

    var body: some View {
        if isStatic {
            column
        } else {
            ScrollView(.vertical) { column }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pane.title)
                .font(Font.lookTitle)
                .foregroundColor(Color.lookInk)
                .accessibilityAddTraits(.isHeader)
            Text(pane.subtitle)
                .font(Font.lookLine)
                .foregroundColor(Color.lookInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 20) {
            header.settingsArrive(0)
            content
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 46)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
