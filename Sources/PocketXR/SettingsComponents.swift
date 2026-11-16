import AppKit
import PocketXRCore
import SwiftUI

// The settings window's parts in Pocket XR's look: cards with a hairline rim, rows, a switch, a slider, a segmented
// picker with a sliding highlight, buttons, chips and key caps. Light marks focus and what is held; nothing casts a
// shadow and nothing bounces.

/// Sizes for a desktop: the phone's pills are 52 high, the Mac's controls about 32 and its rows 44.
enum SettingsMetrics {
    static let row: CGFloat = 44
    static let button: CGFloat = 32
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 200
    static let inset: CGFloat = 16
    static let rise: CGFloat = 12
    static let stagger: Double = 0.06
    static let danger = Color(.sRGB, red: 0.898, green: 0.282, blue: 0.302, opacity: 1)
}

private struct SettingsStaticKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// True while a pane is drawn to a picture file: nothing scrolls, nothing waits to arrive.
    var settingsStatic: Bool {
        get { self[SettingsStaticKey.self] }
        set { self[SettingsStaticKey.self] = newValue }
    }
}

// MARK: arriving

/// A card's arrival on a pane change: a fade and a 12 pt rise, each card 60 ms after the one before (the Android
/// tour's `arrive`). With Reduce Motion it only fades.
struct SettingsArrive: ViewModifier {
    let order: Int
    @State private var shown: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsStatic) private var isStatic

    func body(content: Content) -> some View {
        let visible: Bool = shown || isStatic
        let rise: CGFloat = (visible || reduceMotion) ? 0 : SettingsMetrics.rise
        return content
            .opacity(visible ? 1 : 0)
            .offset(x: 0, y: rise)
            .onAppear { arrive() }
    }

    private func arrive() {
        guard !shown else { return }
        let delay: Double = reduceMotion ? 0 : SettingsMetrics.stagger * Double(order)
        withAnimation(Animation.lookEnter().delay(delay)) { shown = true }
    }
}

extension View {
    func settingsArrive(_ order: Int) -> some View {
        modifier(SettingsArrive(order: order))
    }
}

// MARK: cards and rows

/// A group of rows on the card colour with a hairline rim, an optional heading above it.
struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(Font.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color.lookInk2)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.lookCard)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                        .strokeBorder(Color.lookRim, lineWidth: 1)
                )
        }
    }
}

/// The hairline between two rows of a card.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, SettingsMetrics.inset)
    }
}

/// One row: what it is on the left (with an optional line under it), its control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let note: String?
    let trailing: Trailing

    init(_ title: String, note: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.note = note
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowText(title: title, note: note)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, note == nil ? 6 : 10)
        .frame(minHeight: SettingsMetrics.row)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, note: String? = nil) {
        self.init(title, note: note) { EmptyView() }
    }
}

struct SettingsRowText: View {
    let title: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Font.lookLine)
                .foregroundColor(Color.lookInk)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row whose control is too wide to sit beside its name: the name above, the control under it.
struct SettingsStackedRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Font.lookLine)
                .foregroundColor(Color.lookInk)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, 10)
    }
}

/// A line of plain words inside a card.
struct SettingsNote: View {
    let text: String
    var warn: Bool = false

    init(_ text: String, warn: Bool = false) {
        self.text = text
        self.warn = warn
    }

    var body: some View {
        Text(text)
            .font(Font.lookNote)
            .foregroundColor(warn ? Color.lookWarn : Color.lookInk2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.vertical, 10)
    }
}

// MARK: switch

/// The switch: accent when on, the knob slides without overshoot.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    let label: String
    let enabled: Bool
    @FocusState private var focused: Bool
    @State private var hover: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isOn: Binding<Bool>, label: String, enabled: Bool = true) {
        self._isOn = isOn
        self.label = label
        self.enabled = enabled
    }

    var body: some View {
        Button(action: flip) { face }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($focused)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(isOn ? "On" : "Off"))
    }

    private var trackColor: Color {
        if isOn { return hover ? Color.lookHeld : Color.lookAccent }
        return hover ? Color.lookGlassHover : Look.control.color
    }

    private var face: some View {
        let knobX: CGFloat = isOn ? 8 : -8
        return ZStack {
            Capsule()
                .fill(trackColor)
                .frame(width: 36, height: 20)
            Capsule()
                .strokeBorder(Color.lookRim, lineWidth: 1)
                .frame(width: 36, height: 20)
            Circle()
                .fill(Color.white)
                .frame(width: 16, height: 16)
                .offset(x: knobX, y: 0)
            Capsule()
                .strokeBorder(Color.lookAccent, lineWidth: 2)
                .frame(width: 42, height: 26)
                .opacity(focused ? 1 : 0)
        }
        .frame(width: 44, height: 28)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : Animation.lookEnter(0.18), value: isOn)
        .animation(Animation.lookEnter(Look.quick), value: hover)
    }

    private func flip() {
        isOn.toggle()
    }
}

/// A row with a switch.
struct SettingsToggleRow: View {
    let title: String
    let note: String?
    @Binding var isOn: Bool
    let enabled: Bool

    init(_ title: String, note: String? = nil, isOn: Binding<Bool>, enabled: Bool = true) {
        self.title = title
        self.note = note
        self._isOn = isOn
        self.enabled = enabled
    }

    var body: some View {
        SettingsRow(title, note: note) {
            SettingsToggle(isOn: $isOn, label: title, enabled: enabled)
        }
    }
}

// MARK: slider

/// The slider: a thin track, accent up to the thumb, a white thumb that takes an accent glow while it is held.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let valueText: String
    @State private var dragging: Bool = false
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    private static let thumb: CGFloat = 16

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String, valueText: String) {
        self._value = value
        self.range = range
        self.step = step
        self.label = label
        self.valueText = valueText
    }

    var body: some View {
        GeometryReader { geo in
            track(width: geo.size.width)
        }
        .frame(height: 28)
        .frame(minWidth: 80)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onMoveCommand { direction in move(direction) }
        .onHover { hover = $0 }
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(valueText))
        .accessibilityAdjustableAction { direction in adjust(direction) }
    }

    private var fraction: Double {
        let span: Double = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func track(width: CGFloat) -> some View {
        let travel: CGFloat = max(width - Self.thumb, 1)
        let x: CGFloat = CGFloat(fraction) * travel
        let held: Bool = dragging || focused
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: width, height: 4)
            Capsule()
                .fill(Color.lookAccent)
                .frame(width: x + Self.thumb / 2, height: 4)
            Circle()
                .fill(Color.lookAccent.opacity(0.30))
                .frame(width: 28, height: 28)
                .offset(x: x - 6, y: 0)
                .opacity(held ? 1 : (hover ? 0.4 : 0))
            Circle()
                .fill(Color.white)
                .frame(width: Self.thumb, height: Self.thumb)
                .offset(x: x, y: 0)
        }
        .frame(width: width, height: 28, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(drag(width: width))
        .animation(Animation.lookEnter(Look.quick), value: held)
        .animation(Animation.lookEnter(Look.quick), value: hover)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                dragging = true
                set(x: g.location.x, width: width)
            }
            .onEnded { _ in dragging = false }
    }

    private func set(x: CGFloat, width: CGFloat) {
        let travel: CGFloat = max(width - Self.thumb, 1)
        let f: Double = Double(min(max((x - Self.thumb / 2) / travel, 0), 1))
        let raw: Double = range.lowerBound + f * (range.upperBound - range.lowerBound)
        commit(raw)
    }

    private func commit(_ raw: Double) {
        let steps: Double = ((raw - range.lowerBound) / step).rounded()
        let snapped: Double = range.lowerBound + steps * step
        let next: Double = min(max(snapped, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .down: commit(value - step)
        case .right, .up: commit(value + step)
        default: break
        }
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: commit(value + step)
        case .decrement: commit(value - step)
        default: break
        }
    }
}

/// A row with a slider: the name, the slider, and the value in digits that keep their width.
struct SettingsSliderRow: View {
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
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(Font.lookLine)
                .foregroundColor(Color.lookInk)
                .frame(width: 150, alignment: .leading)
            SettingsSlider(value: $value, range: range, step: step, label: title, valueText: valueText)
            Text(valueText)
                .font(Font.system(size: 14, weight: .regular).monospacedDigit())
                .foregroundColor(Color.lookInk2)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .frame(minHeight: SettingsMetrics.row)
    }
}

// MARK: segmented picker

/// A choice of a few values; the accent highlight slides from the old choice to the new one.
struct SettingsSegmented<T: Hashable>: View {
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
                SettingsSegment(
                    text: title(pair.element),
                    selected: pair.element == selection,
                    space: space,
                    action: { pick(pair.element) }
                )
            }
        }
        .padding(2)
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

struct SettingsSegment: View {
    let text: String
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    init(text: String, selected: Bool, space: Namespace.ID, action: @escaping () -> Void) {
        self.text = text
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
            .accessibilityLabel(Text(text))
            .accessibilityValue(Text(selected ? "Selected" : ""))
    }

    private var face: some View {
        Text(text)
            .font(Font.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundColor(selected ? Color.lookPage : Color.lookInk)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 36, minHeight: 28)
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

// MARK: buttons

enum SettingsButtonKind {
    /// The one main action of a card: accent.
    case primary
    /// Everything else: glass with a rim.
    case glass
    /// Something that cannot be undone.
    case danger
}

struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(Animation.lookEnter(Look.quick), value: configuration.isPressed)
    }
}

/// A pill button, 32 high.
struct SettingsButton: View {
    let title: String
    let symbol: String?
    let kind: SettingsButtonKind
    let enabled: Bool
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    init(_ title: String, symbol: String? = nil, kind: SettingsButtonKind = .glass, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(SettingsPressStyle())
            .focusEffectDisabled()
            .focused($focused)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(title))
    }

    private var fill: Color {
        switch kind {
        case .primary: return hover ? Color.lookHeld : Color.lookAccent
        case .glass: return hover ? Color.lookGlassHover : Look.control.color.opacity(0.55)
        case .danger: return hover ? SettingsMetrics.danger.opacity(0.28) : SettingsMetrics.danger.opacity(0.14)
        }
    }

    private var ink: Color {
        switch kind {
        case .primary: return Color.lookPage
        case .glass: return Color.lookInk
        case .danger: return Color(.sRGB, red: 1.0, green: 0.56, blue: 0.56, opacity: 1)
        }
    }

    private var rim: Color {
        switch kind {
        case .primary: return Color.clear
        case .glass: return hover ? Color.lookRimFocus : Color.lookRim
        case .danger: return SettingsMetrics.danger.opacity(0.5)
        }
    }

    private var face: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Font.system(size: 12, weight: .medium))
            }
            Text(title)
                .font(Font.lookButton)
                .lineLimit(1)
        }
        .foregroundColor(ink)
        .padding(.horizontal, 14)
        .frame(height: SettingsMetrics.button)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(rim, lineWidth: 1))
        .overlay(
            Capsule()
                .strokeBorder(kind == .primary ? Color.white : Color.lookAccent, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .contentShape(Capsule())
        .animation(Animation.lookEnter(Look.quick), value: hover)
    }
}

/// A small round button with only a symbol (rename, delete).
struct SettingsIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    init(symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(SettingsPressStyle())
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(label))
            .help(label)
    }

    private var face: some View {
        Image(systemName: symbol)
            .font(Font.system(size: 12, weight: .medium))
            .foregroundColor(hover ? Color.lookInk : Color.lookInk2)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.lookGlassHover).opacity(hover ? 1 : 0))
            .overlay(Circle().strokeBorder(Color.lookAccent, lineWidth: 2).opacity(focused ? 1 : 0))
            .contentShape(Circle())
            .animation(Animation.lookEnter(Look.quick), value: hover)
    }
}

// MARK: small pieces

/// A small label in a capsule: "3D", "Steady". Lit ones take the accent.
struct SettingsChip: View {
    let text: String
    let lit: Bool

    init(_ text: String, lit: Bool = false) {
        self.text = text
        self.lit = lit
    }

    var body: some View {
        Text(text)
            .font(Font.lookChip)
            .foregroundColor(lit ? Color.lookHeld : Color.lookInk3)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(lit ? Color.lookAccent.opacity(0.16) : Color.clear))
            .overlay(Capsule().strokeBorder(lit ? Color.lookAccent.opacity(0.5) : Color.lookRim, lineWidth: 1))
    }
}

/// A status dot: the accent when lit, dim otherwise, with a soft halo of light when lit.
struct SettingsDot: View {
    let lit: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.lookAccent.opacity(0.25))
                .frame(width: 14, height: 14)
                .opacity(lit ? 1 : 0)
            Circle()
                .fill(lit ? Color.lookAccent : Color.lookInk3)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .animation(Animation.lookEnter(), value: lit)
        .accessibilityHidden(true)
    }
}

/// One key of a shortcut, drawn as a small glass key.
struct SettingsKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.system(size: 12.5, weight: .medium))
            .foregroundColor(Color.lookInk)
            .frame(minWidth: 14)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Look.glassTop.color, Look.glassBottom.color],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.lookRim, lineWidth: 1)
            )
    }
}

/// A shortcut's keys side by side: "⌃⌥R" as three keys.
struct SettingsKeys: View {
    let keys: String

    var body: some View {
        let parts: [String] = keys.map { String($0) }
        return HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { pair in
                SettingsKeyCap(text: pair.element)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SettingsKeys.spoken(keys)))
    }

    /// The keys as VoiceOver should say them.
    static func spoken(_ keys: String) -> String {
        let words: [String] = keys.map { c -> String in
            switch c {
            case "⌃": return "Control"
            case "⌥": return "Option"
            case "⌘": return "Command"
            case "⇧": return "Shift"
            case "=": return "equals"
            case "-": return "minus"
            case "]": return "right bracket"
            case "[": return "left bracket"
            case ".": return "full stop"
            case ",": return "comma"
            default: return String(c)
            }
        }
        return words.joined(separator: " ")
    }
}

/// One colour to pick; the picked one wears a ring of light.
struct SettingsSwatch: View {
    let color: Color
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    init(color: Color, name: String, selected: Bool, action: @escaping () -> Void) {
        self.color = color
        self.name = name
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(SettingsPressStyle())
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(selected ? "Selected" : ""))
            .help(name)
    }

    private var face: some View {
        let ring: Bool = selected || focused
        return ZStack {
            Circle()
                .strokeBorder(focused ? Color.lookAccent : Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: 26, height: 26)
                .opacity(ring ? 1 : (hover ? 0.35 : 0))
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .animation(Animation.lookEnter(Look.quick), value: ring)
        .animation(Animation.lookEnter(Look.quick), value: hover)
    }
}

/// A word and a number side by side, the number in digits that keep their width (the live readings).
struct SettingsReading: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Font.lookChip)
                .foregroundColor(Color.lookInk3)
            Text(value)
                .font(Font.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundColor(Color.lookInk)
                .lineLimit(1)
        }
        .frame(minWidth: 84, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}
