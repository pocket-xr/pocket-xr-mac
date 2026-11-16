import PocketXRCore
import SwiftUI

// The tour's words, step by step, and the small parts they are built from: the numbered title, numbered lines whose
// circle turns to the accent with a tick, the setup checklist's rows, the Arrange step's controls. Everything that
// arrives fades in and rises 12 points, 60 ms after the thing before it; with Reduce Motion it is simply there.

/// One step's words.
@MainActor
struct TourWords: View {
    let step: TourStep
    @ObservedObject var model: TourModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: TourActionsRef
    let reduced: Bool
    let fixedTime: Double?

    private var connected: Bool { state.glassesName != nil }
    private var ready: Bool { TourModel.ready(state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepWords
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stepWords: some View {
        switch step {
        case .welcome: welcomeStep
        case .setup: setupStep
        case .screens: screensStep
        case .look: lookStep
        case .arrange: arrangeStep
        case .depth: depthStep
        case .menu: menuStep
        case .done: doneStep
        }
    }

    private func title(_ step: TourStep) -> some View {
        TourTitle(number: step.number, text: TourCopy.title(step, ready: ready))
            .tourArrive(1, reduced)
    }

    /// The lines of a step whose picture loops light as the picture reaches them.
    private func phased<Content: View>(_ step: TourStep, follow: Bool = true, @ViewBuilder content: @escaping (Int) -> Content) -> some View {
        TourPhased(step: step, start: model.start(of: step), reduced: reduced || !follow, fixedTime: follow ? fixedTime : nil, content: content)
    }

    // ---- 1. Welcome ----

    private var welcomeStep: some View {
        Group {
            title(.welcome)
            TourBody(text: TourCopy.welcomeBody).tourArrive(2, reduced)
            TourNote(text: TourCopy.welcomeNote).tourArrive(3, reduced)
        }
    }

    // ---- 2. Get set up ----

    private var setupStep: some View {
        Group {
            title(.setup)
            TourBody(text: TourCopy.setupBody).tourArrive(2, reduced)
            VStack(spacing: 0) {
                glassesRow
                TourRule()
                recordingRow
                TourRule()
                loginRow
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.lookCard))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.lookRim, lineWidth: 1))
            .padding(.top, 14)
            .tourArrive(3, reduced)
        }
    }

    private var glassesRow: some View {
        let name: String = state.glassesName ?? TourCopy.glasses
        var line: String = TourCopy.glassesUnplugged
        var detail: String? = nil
        var note: String? = nil
        if connected {
            line = TourCopy.glassesConnected(name)
            if let display = state.displayText {
                detail = TourCopy.glassesDisplay(display)
            } else {
                detail = TourCopy.glassesNoDisplay
            }
            if let support = Tour.support(state.glassesFamily) {
                note = TourCopy.support(support, name: name)
            }
        }
        return TourSetupRow(done: connected, optional: false, title: TourCopy.glasses, line: line, detail: detail, note: note, actions: [], toggle: nil, reduced: reduced)
    }

    private var recordingRow: some View {
        let allowed: Bool = state.screenRecordingAllowed
        let target = actions
        var buttons: [TourAction] = []
        if !allowed {
            buttons.append(TourAction(id: TourCopy.recordingAllow, primary: true, run: { target.target?.requestScreenRecording() }))
            buttons.append(TourAction(id: TourCopy.recordingSettings, primary: false, run: { target.target?.openScreenRecordingSettings() }))
        }
        return TourSetupRow(
            done: allowed,
            optional: false,
            title: TourCopy.recording,
            line: allowed ? TourCopy.recordingAllowed : TourCopy.recordingNotAllowed,
            detail: allowed ? TourCopy.recordingMonthly : TourCopy.recordingWhy,
            note: allowed ? nil : TourCopy.recordingReopen,
            actions: buttons,
            toggle: nil,
            reduced: reduced
        )
    }

    private var loginRow: some View {
        TourSetupRow(
            done: store.s.launchAtLogin,
            optional: true,
            title: TourCopy.login,
            line: TourCopy.loginLine,
            detail: nil,
            note: nil,
            actions: [],
            toggle: $store.s.launchAtLogin,
            reduced: reduced
        )
    }

    // ---- 3. Your screens are real displays ----

    private var screensStep: some View {
        Group {
            title(.screens)
            TourBody(text: TourCopy.screensBody).tourArrive(2, reduced)
            phased(.screens) { phase in
                VStack(alignment: .leading, spacing: 8) {
                    // The first line ticks when the pointer has really been on a floating screen.
                    TourLine(number: 1, text: TourCopy.screensPointer, lit: phase == 0, done: state.pointerVisitedScreen, reduced: reduced)
                    TourLine(number: 2, text: TourCopy.screensDrag, lit: phase == 1, done: false, reduced: reduced)
                    TourLine(number: 3, text: TourCopy.screensCount, lit: false, done: false, reduced: reduced)
                }
            }
            .padding(.top, 14)
            .tourArrive(3, reduced)
        }
    }

    // ---- 4. Look around ----

    private var lookStep: some View {
        let target = actions
        return Group {
            title(.look)
            TourBody(text: TourCopy.lookBody).tourArrive(2, reduced)
            TourBody(text: TourCopy.lookRecentre()).tourArrive(3, reduced)
            // Ticks only when Recentre is really used while this step is showing, so the flag starts clear here.
            TourLine(number: 1, text: TourCopy.lookTry(), lit: false, done: state.recentred, reduced: reduced)
                .padding(.top, 14)
                .tourArrive(4, reduced)
                .onAppear {
                    if fixedTime == nil { state.recentred = false }
                }
            Button(TourCopy.recentre, action: { target.target?.recentre() })
                .buttonStyle(TourPillStyle(primary: false, height: 32, minWidth: 0))
                .padding(.top, 14)
                .tourArrive(5, reduced)
        }
    }

    // ---- 5. Make the Space yours ----

    /// A setting of the Space, bound so that the first change stops the picture's own demonstration.
    private func setting<Value>(_ path: WritableKeyPath<SpaceSettings, Value>) -> Binding<Value> {
        let settings = store
        let tour = model
        return Binding<Value>(
            get: { settings.s[keyPath: path] },
            set: { value in
                tour.touchArrange()
                settings.s[keyPath: path] = value
            }
        )
    }

    private var arrangeStep: some View {
        Group {
            title(.arrange)
            TourBody(text: TourCopy.arrangeBody).tourArrive(2, reduced)
            phased(.arrange, follow: !model.arrangeTouched) { phase in
                arrangeControls(phase)
            }
            .padding(.top, 14)
            .tourArrive(3, reduced)
            TourNote(text: TourCopy.arrangeNote).tourArrive(4, reduced)
        }
    }

    private func arrangeControls(_ phase: Int) -> some View {
        let s = store.s
        return VStack(alignment: .leading, spacing: 10) {
            TourControlRow(
                title: TourCopy.arrangeSize,
                valueText: TourCopy.sizeValue(s.widthDeg),
                keys: [TourCopy.keys("smaller"), TourCopy.keys("bigger")],
                lit: phase == 0,
                value: setting(\.widthDeg),
                range: SpaceSettings.widthRange,
                step: 1
            )
            TourControlRow(
                title: TourCopy.arrangeDistance,
                valueText: TourCopy.distanceValue(s.distance),
                keys: [TourCopy.keys("nearer"), TourCopy.keys("further")],
                lit: phase == 1,
                value: setting(\.distance),
                range: SpaceSettings.distanceRange,
                step: 0.1
            )
            TourControlRow(
                title: TourCopy.arrangeCurve,
                valueText: TourCopy.curveValue(s.curve),
                keys: [TourCopy.keys("lessCurve"), TourCopy.keys("moreCurve")],
                lit: phase == 2,
                value: setting(\.curve),
                range: SpaceSettings.curveRange,
                step: 0.1
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TourMark(lit: false)
                    Text(TourCopy.arrangeLayout).font(Font.lookHeading).foregroundColor(Color.lookInk)
                    Spacer(minLength: 8)
                    TourKeys(text: TourCopy.keys("layout"))
                }
                TourLayoutPicker(layout: setting(\.layout))
            }
        }
    }

    // ---- 6. 3D and Steady mode ----

    private var depthStep: some View {
        Group {
            title(.depth)
            phased(.depth) { phase in
                VStack(alignment: .leading, spacing: 16) {
                    TourTopic(name: TourCopy.depth3D, line: TourCopy.depth3DLine, note: TourCopy.depth3DNote(), lit: phase == 0, reduced: reduced)
                    TourTopic(name: TourCopy.steady, line: TourCopy.steadyLine(), note: TourCopy.steadyNote, lit: phase == 1, reduced: reduced)
                }
            }
            .padding(.top, 16)
            .tourArrive(2, reduced)
        }
    }

    // ---- 7. Always in your menu bar ----

    private var menuStep: some View {
        Group {
            title(.menu)
            TourBody(text: TourCopy.menuBody).tourArrive(2, reduced)
            phased(.menu) { phase in
                VStack(alignment: .leading, spacing: 8) {
                    TourLine(number: 1, text: TourCopy.menuOpen, lit: phase == 0, done: false, reduced: reduced)
                    TourLine(number: 2, text: TourCopy.menuQuit, lit: phase == 1, done: false, reduced: reduced)
                    TourLine(number: 3, text: TourCopy.menuUnplug, lit: phase == 2, done: false, reduced: reduced)
                }
            }
            .padding(.top, 14)
            .tourArrive(3, reduced)
        }
    }

    // ---- 8. You're set ----

    private var doneStep: some View {
        let open: [Tour.Remaining] = Tour.remaining(glassesConnected: connected, screenRecordingAllowed: state.screenRecordingAllowed, capturing: state.capturing)
        let tour = model
        return Group {
            title(.done)
            if open.isEmpty {
                TourBody(text: TourCopy.doneReady).tourArrive(2, reduced)
            } else {
                TourBody(text: TourCopy.doneOpen).tourArrive(2, reduced)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(open.enumerated()), id: \.offset) { pair in
                        TourLine(number: pair.offset + 1, text: TourCopy.remaining(pair.element), lit: false, done: false, reduced: reduced)
                    }
                }
                .padding(.top, 14)
                .tourArrive(3, reduced)
                Button(TourCopy.doneToSetup, action: { tour.go(.setup) })
                    .buttonStyle(TourPillStyle(primary: false, height: 32, minWidth: 0))
                    .padding(.top, 14)
                    .tourArrive(3, reduced)
            }
            TourNote(text: TourCopy.doneAgain).tourArrive(4, reduced)
            TourNote(text: TourCopy.doneShortcuts).padding(.top, -6).tourArrive(5, reduced)
        }
    }
}

// ---- arriving ----

/// Fades in and rises 12 points, [order] times 60 ms after the step came up: the picture, the title, the body, the
/// list, the note.
struct TourArrive: ViewModifier {
    let order: Int
    let reduced: Bool
    @State private var shown: Bool

    init(order: Int, reduced: Bool) {
        self.order = order
        self.reduced = reduced
        _shown = State(initialValue: reduced)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: 0, y: shown ? 0 : 12)
            .onAppear {
                if shown { return }
                withAnimation(Animation.lookEnter().delay(0.06 * Double(order))) {
                    shown = true
                }
            }
    }
}

extension View {
    func tourArrive(_ order: Int, _ reduced: Bool) -> some View {
        modifier(TourArrive(order: order, reduced: reduced))
    }
}

/// Gives its content the line the picture is showing now (-1 for none), a few times a second.
@MainActor
struct TourPhased<Content: View>: View {
    let step: TourStep
    let start: Date
    let reduced: Bool
    let fixedTime: Double?
    let content: (Int) -> Content

    init(step: TourStep, start: Date, reduced: Bool, fixedTime: Double?, @ViewBuilder content: @escaping (Int) -> Content) {
        self.step = step
        self.start = start
        self.reduced = reduced
        self.fixedTime = fixedTime
        self.content = content
    }

    var body: some View {
        if let fixedTime {
            content(Tour.phase(step, fixedTime))
        } else if reduced {
            content(-1)
        } else {
            TimelineView(.periodic(from: start, by: 0.1)) { timeline in
                content(Tour.phase(step, timeline.date.timeIntervalSince(start)))
            }
        }
    }
}

// ---- words ----

/// The step's number in the accent, and its title: a heading for VoiceOver.
@MainActor
struct TourTitle: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Font.system(size: 16, weight: .medium))
                .foregroundColor(Color.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.lookAccent))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(Font.lookTitle)
                .foregroundColor(Color.lookInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct TourBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.lookBody)
            .foregroundColor(Color.lookInk2)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }
}

@MainActor
struct TourNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.lookNote)
            .foregroundColor(Color.lookInk3)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
    }
}

/// A tick as two strokes, drawn by trimming the path.
struct TourTickShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: Double = Double(min(rect.width, rect.height)) / 2
        let cx: Double = Double(rect.midX)
        let cy: Double = Double(rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: cx - r * 0.42, y: cy + r * 0.02))
        path.addLine(to: CGPoint(x: cx - r * 0.1, y: cy + r * 0.34))
        path.addLine(to: CGPoint(x: cx + r * 0.46, y: cy - r * 0.3))
        return path
    }
}

/// A numbered line. [lit] while the picture is showing it; [done] once the thing has really been done, when the
/// number gives way to a tick.
@MainActor
struct TourLine: View {
    let number: Int
    let text: String
    let lit: Bool
    let done: Bool
    let reduced: Bool

    var body: some View {
        let on: Bool = lit || done
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.lookGlassHover)
                Circle().fill(Color.lookAccent).opacity(on ? 1 : 0)
                Text("\(number)")
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundColor(on ? Color.white : Color.lookInk2)
                    .opacity(done ? 0 : 1)
                TourTickShape()
                    .trim(from: 0, to: done ? 1 : 0)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            Text(text)
                .font(Font.lookLine)
                .foregroundColor(on ? Color.lookInk : Color.lookInk2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduced ? nil : (on ? Animation.lookEnter() : Animation.lookExit()), value: on)
        .animation(reduced ? nil : Animation.lookEnter(), value: done)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(done ? TourCopy.stateDone : ""))
    }
}

/// The small bar that turns to the accent beside the thing the picture is showing.
@MainActor
struct TourMark: View {
    let lit: Bool

    var body: some View {
        ZStack {
            Capsule().fill(Color.lookRim)
            Capsule().fill(Color.lookAccent).opacity(lit ? 1 : 0)
        }
        .frame(width: 3, height: 18)
        .accessibilityHidden(true)
    }
}

/// A named thing with a line about it and, quieter, what holds for it. [lit] while the picture shows it.
@MainActor
struct TourTopic: View {
    let name: String
    let line: String
    let note: String?
    let lit: Bool
    let reduced: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TourMark(lit: lit).padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Font.lookHeading)
                    .foregroundColor(lit ? Color.lookInk : Color.lookInk.opacity(0.82))
                Text(line)
                    .font(Font.lookLine)
                    .foregroundColor(Color.lookInk2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                if let note {
                    Text(note)
                        .font(Font.lookNote)
                        .foregroundColor(Color.lookInk3)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduced ? nil : (lit ? Animation.lookEnter() : Animation.lookExit()), value: lit)
        .accessibilityElement(children: .combine)
    }
}

// ---- the setup checklist ----

@MainActor
struct TourRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.lookRim)
            .frame(height: 1)
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
    }
}

/// A button of a checklist row. Its label is its id.
struct TourAction: Identifiable {
    let id: String
    let primary: Bool
    let run: () -> Void
}

/// One thing to set up: where it stands now, and the button for the next thing to do. The ring fills and the tick
/// draws when it really is done, and VoiceOver reads Done, To do or Optional.
@MainActor
struct TourSetupRow: View {
    let done: Bool
    let optional: Bool
    let title: String
    let line: String
    let detail: String?
    let note: String?
    let actions: [TourAction]
    let toggle: Binding<Bool>?
    let reduced: Bool

    private var stateWord: String {
        if done { return TourCopy.stateDone }
        return optional ? TourCopy.stateOptional : TourCopy.stateToDo
    }

    /// The ring and the tick draw themselves when the thing becomes done, and are simply gone when it is undone.
    private func drawing(_ animation: Animation) -> Animation? {
        (reduced || !done) ? nil : animation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ring
                texts
                if let toggle {
                    TourSwitch(isOn: toggle, label: title)
                }
            }
            if !actions.isEmpty {
                buttons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.lookRimFocus, lineWidth: 2)
            Circle()
                .trim(from: 0, to: done ? 1 : 0)
                .stroke(Color.lookAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(Angle.degrees(-90))
                .animation(drawing(Animation.lookInOut()), value: done)
            TourTickShape()
                .trim(from: 0, to: done ? 1 : 0)
                .stroke(Color.lookAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .animation(drawing(Animation.lookEnter().delay(Look.enter)), value: done)
        }
        .frame(width: 20, height: 20)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Font.lookHeading)
                    .foregroundColor(Color.lookInk)
                if optional && !done {
                    Text(TourCopy.stateOptional)
                        .font(Font.lookChip)
                        .foregroundColor(Color.lookInk2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.lookGlassHover))
                        .accessibilityHidden(true)
                }
            }
            Text(line)
                .font(Font.lookLine)
                .foregroundColor(done ? Color.lookAccent : Color.lookInk2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if let detail {
                Text(detail)
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if let note {
                Text(note)
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateWord))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                Button(action.id, action: action.run)
                    .buttonStyle(TourPillStyle(primary: action.primary, height: 30, minWidth: 0))
            }
        }
        .padding(.leading, 32)
        .padding(.top, 10)
    }
}

// ---- buttons and controls ----

/// A pill: filled with the accent for the main thing to do, outlined for the rest. It lights under the pointer.
struct TourPillStyle: ButtonStyle {
    let primary: Bool
    let height: CGFloat
    let minWidth: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        TourPillFace(label: configuration.label, pressed: configuration.isPressed, primary: primary, height: height, minWidth: minWidth)
    }
}

struct TourPillFace<Face: View>: View {
    let label: Face
    let pressed: Bool
    let primary: Bool
    let height: CGFloat
    let minWidth: CGFloat
    @State private var hovering = false

    init(label: Face, pressed: Bool, primary: Bool, height: CGFloat, minWidth: CGFloat) {
        self.label = label
        self.pressed = pressed
        self.primary = primary
        self.height = height
        self.minWidth = minWidth
    }

    private var fill: Color {
        if primary { return hovering ? Color.lookHeld : Color.lookAccent }
        return hovering ? Color.lookGlassHover : Color.clear
    }

    var body: some View {
        label
            .font(Font.lookButton)
            .foregroundColor(primary ? Color.white : Color.lookInk)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(minWidth: minWidth, minHeight: height)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(primary ? Color.clear : Color.lookRimFocus, lineWidth: 1))
            .opacity(pressed ? 0.8 : 1)
            .contentShape(Capsule())
            .onHover { inside in hovering = inside }
            .animation(Animation.lookEnter(Look.quick), value: hovering)
            .animation(Animation.lookEnter(Look.quick), value: pressed)
    }
}

/// A button that is only its words (Skip).
struct TourQuietStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.lookButton)
            .foregroundColor(Color.lookInk2)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A shortcut's keys, as a chip.
@MainActor
struct TourKeys: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.system(size: 11, weight: .medium))
            .foregroundColor(Color.lookInk2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.lookGlassHover))
            .accessibilityLabel(Text("Shortcut \(text)"))
    }
}

/// A switch drawn in the tour's own look.
@MainActor
struct TourSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button(action: { isOn.toggle() }) {
            ZStack(alignment: isOn ? Alignment.trailing : Alignment.leading) {
                Capsule().fill(isOn ? Color.lookAccent : Color.lookGlassHover)
                Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
            }
            .frame(width: 36, height: 20)
            .overlay(Capsule().stroke(Color.lookRim, lineWidth: 1))
            .frame(width: 40, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Animation.lookEnter(Look.quick), value: isOn)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isOn ? TourCopy.on : TourCopy.off))
    }
}

/// A compact slider: a hairline track that fills with the accent, and a white thumb.
@MainActor
struct TourSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let valueText: String
    @State private var dragging = false

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String, valueText: String) {
        _value = value
        self.range = range
        self.step = step
        self.label = label
        self.valueText = valueText
    }

    private var fraction: Double {
        let width: Double = range.upperBound - range.lowerBound
        if width <= 0 { return 0 }
        return min(max((value - range.lowerBound) / width, 0), 1)
    }

    private func move(to fraction: Double) {
        let k: Double = min(max(fraction, 0), 1)
        let raw: Double = range.lowerBound + (range.upperBound - range.lowerBound) * k
        let stepped: Double = step > 0 ? (raw / step).rounded() * step : raw
        let next: Double = min(max(stepped, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }

    private func nudge(_ steps: Double) {
        let width: Double = range.upperBound - range.lowerBound
        if width <= 0 { return }
        let unit: Double = step > 0 ? step : width / 20
        move(to: (value + unit * steps - range.lowerBound) / width)
    }

    var body: some View {
        GeometryReader { geo in
            let width: Double = Double(geo.size.width)
            let travel: Double = max(width - 16, 1)
            let x: Double = 8 + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.lookRim).frame(height: 4)
                Capsule().fill(Color.lookAccent).frame(width: CGFloat(x), height: 4)
                Circle()
                    .fill(Color.lookAccent.opacity(dragging ? 0.3 : 0))
                    .frame(width: 26, height: 26)
                    .offset(x: CGFloat(x - 13), y: 0)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat(x - 7), y: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        move(to: (Double(drag.location.x) - 8) / travel)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 28)
        .animation(Animation.lookEnter(Look.quick), value: dragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(valueText))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }
}

/// One of the Arrange step's controls: its name, its value now, the keys that do the same, and the slider.
@MainActor
struct TourControlRow: View {
    let title: String
    let valueText: String
    let keys: [String]
    let lit: Bool
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TourMark(lit: lit)
                Text(title)
                    .font(Font.lookHeading)
                    .foregroundColor(Color.lookInk)
                Text(valueText)
                    .font(Font.lookLine)
                    .foregroundColor(Color.lookInk2)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                ForEach(keys, id: \.self) { item in
                    TourKeys(text: item)
                }
            }
            TourSlider(value: value, range: range, step: step, label: title, valueText: valueText)
        }
        .animation(Animation.lookEnter(), value: lit)
    }
}

/// The four layouts, as one row to pick from.
@MainActor
struct TourLayoutPicker: View {
    let layout: Binding<ArrangeLayout>

    var body: some View {
        let current: ArrangeLayout = layout.wrappedValue
        HStack(spacing: 4) {
            ForEach(ArrangeLayout.allCases, id: \.rawValue) { item in
                TourLayoutChoice(name: TourCopy.layoutName(item), on: item == current, pick: { layout.wrappedValue = item })
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.lookCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lookRim, lineWidth: 1))
        .animation(Animation.lookEnter(Look.quick), value: current)
    }
}

@MainActor
struct TourLayoutChoice: View {
    let name: String
    let on: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            Text(name)
                .font(Font.system(size: 12, weight: .medium))
                .foregroundColor(on ? Color.white : Color.lookInk2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Color.lookAccent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(on ? TourCopy.on : TourCopy.off))
    }
}
