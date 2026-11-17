import AppKit
import PocketXRCore
import SwiftUI

// The settings for a game controller and for Pocket mode: two cards in the settings window's style.

extension ControllerMode {
    var title: String {
        switch self {
        case .off: return "Off"
        case .held: return "While holding the left stick in"
        case .always: return "Always"
        }
    }

    var detail: String {
        switch self {
        case .off: return "The controller is left to your games."
        case .held: return "Press the left stick in and keep it in to use the controls below. Let go, and the controller is your game's again."
        case .always: return "The controls below work all the time. For when you are not playing a game."
        }
    }
}

/// The settings for controllers and Pocket mode, as cards for the settings window's Input pane.
struct ControllerSettingsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            controllerCard
            pocketCard
        }
    }

    // MARK: game controller

    private var controllerCard: some View {
        let mode: ControllerMode = store.s.controllerMode
        return SettingsCard("Game controller") {
            connectedRow
            SettingsDivider()
            ControllerCaption("Use it to move and resize your screens")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ControllerMode.allCases, id: \.rawValue) { choice in
                    ControllerChoiceRow(
                        title: choice.title,
                        note: choice.detail,
                        selected: choice == mode,
                        action: { pick(choice) }
                    )
                }
            }
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("When the controller changes your screens"))
            SettingsDivider()
            ControllerCaption("What each control does")
            ControllerDiagram(mode: mode)
                .padding(.horizontal, SettingsMetrics.inset)
                .padding(.top, 2)
                .padding(.bottom, 12)
            SettingsDivider()
            SettingsNote("Not tried with a controller on a Mac yet. It moves, resizes and recentres your screens; it does not click for you.")
        }
    }

    private var connectedNote: String {
        guard state.controllerName != nil else {
            return "Connect a DualSense, Xbox or Switch Pro controller, or a pair of Joy-Cons, with Bluetooth or a cable."
        }
        switch store.s.controllerMode {
        case .off: return "Left to your games."
        case .held: return "Hold the left stick in to use it on your screens."
        case .always: return "Changes your screens all the time."
        }
    }

    private var connectedRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(Font.system(size: 15, weight: .regular))
                .foregroundColor(state.controllerName == nil ? Color.lookInk3 : Color.lookHeld)
                .frame(width: 24, alignment: .center)
                .accessibilityHidden(true)
            SettingsRowText(
                title: state.controllerName ?? "No controller connected",
                note: connectedNote
            )
            Spacer(minLength: 12)
            if state.controllerName != nil {
                SettingsChip("Connected", lit: true)
            }
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsMetrics.row)
    }

    private func pick(_ choice: ControllerMode) {
        guard store.s.controllerMode != choice else { return }
        withAnimation(Animation.lookEnter(0.22)) { store.s.controllerMode = choice }
    }

    // MARK: Pocket mode

    private var pocketBinding: Binding<Bool> {
        let ref: SettingsActionsRef = actions
        let current: AppState = state
        // Controls only ever call these on the main thread.
        return Binding<Bool>(
            get: {
                MainActor.assumeIsolated { current.pocketMode }
            },
            set: { on in
                MainActor.assumeIsolated {
                    if let target = ref.target { target.setPocketMode(on) }
                }
            }
        )
    }

    private var pocketShortcut: Shortcut? {
        Shortcut.all.first { $0.id == "pocket" }
    }

    private var pocketCard: some View {
        let ready: Bool = state.virtualScreens > 0
        return SettingsCard("Pocket mode") {
            SettingsToggleRow(
                "Pocket mode",
                note: "Your Mac's own screen goes black and the pointer stays on your floating screens. Everything lives in the glasses: for a train or a plane, and so the pointer never strays onto a screen you are not looking at.",
                isOn: pocketBinding,
                enabled: ready || state.pocketMode
            )
            if !ready {
                SettingsNote("Plug in your glasses first", warn: true)
            }
            if let shortcut = pocketShortcut {
                SettingsDivider()
                SettingsRow(
                    "Turn it on and off from the keyboard",
                    note: store.s.shortcuts ? nil : "Keyboard shortcuts are switched off, under Shortcuts."
                ) {
                    SettingsKeys(keys: shortcut.keys)
                        .opacity(store.s.shortcuts ? 1 : 0.45)
                }
            }
            SettingsDivider()
            SettingsRow(
                "Leave without the keyboard",
                note: "Hold the trackpad button and move back onto your Mac's screen, then keep holding for a second."
            ) {
                PocketHoldGlyph()
            }
            SettingsDivider()
            SettingsNote("It ends by itself when the glasses are unplugged. The screen is covered in black, not switched off, so the backlight of an LCD stays on. Not tried with glasses on a Mac yet.")
        }
    }
}

/// A small heading inside a card, above a group of rows.
struct ControllerCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Font.lookLine)
            .foregroundColor(Color.lookInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One of a few choices, each with a line saying what it means; the chosen one wears the accent.
struct ControllerChoiceRow: View {
    let title: String
    let note: String
    let selected: Bool
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(note))
            .accessibilityValue(Text(selected ? "Selected" : ""))
    }

    private var mark: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? Color.lookAccent : Color.lookRimFocus, lineWidth: 1.5)
            Circle()
                .fill(Color.lookAccent)
                .frame(width: 8, height: 8)
                .opacity(selected ? 1 : 0)
        }
        .frame(width: 18, height: 18)
        .frame(width: 24, alignment: .center)
    }

    private var face: some View {
        HStack(alignment: .top, spacing: 12) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundColor(Color.lookInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.inset - 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .fill(Color.lookGlassHover)
                .opacity(hover && !selected ? 0.6 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(Color.lookAccent, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .animation(Animation.lookEnter(Look.quick), value: hover)
    }
}

/// The black screen's lock in its ring, small, part filled: what holding to leave looks like.
struct PocketHoldGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.62)
                .stroke(Color.lookHeld, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(Angle(degrees: -90))
            Image(systemName: "lock.fill")
                .font(Font.system(size: 10, weight: .regular))
                .foregroundColor(Color.lookInk2)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
