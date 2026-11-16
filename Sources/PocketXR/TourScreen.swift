import AppKit
import PocketXRCore
import SwiftUI

// The tour's screen (the Android app's TourScreen.kt, for a Mac window): the picture on the left, bleeding to the
// window's edge, and a few words on the right, one idea per step, with Skip, Back and Next on every step. The steps
// and what is said for these glasses come from the core's Tour; this draws them.

/// A value that glides to each new target on the enter curve, read while drawing (so a new frame costs nothing else).
struct TourEased {
    var from: Double
    var to: Double
    var at: Double = 0
    var duration: Double

    init(_ value: Double, duration: Double = Look.enter) {
        self.from = value
        self.to = value
        self.duration = duration
    }

    func value(_ now: Double) -> Double {
        let k: Double = LookEase.enter(LookEase.span(now, at, at + duration))
        return from + (to - from) * k
    }

    /// Glide to [target] from wherever the value is at [now].
    mutating func set(_ target: Double, now: Double) {
        let current: Double = value(now)
        from = current
        to = target
        at = now
    }

    mutating func snap(_ value: Double) {
        from = value
        to = value
    }
}

/// The app's actions, held weakly so the tour's window does not keep the app's controller alive.
@MainActor
final class TourActionsRef {
    weak var target: AppActions?

    init(_ target: AppActions?) {
        self.target = target
    }
}

/// Which step is showing, and what the pictures need that changes over time.
@MainActor
final class TourModel: ObservableObject {
    @Published var step: TourStep
    /// The way the last move went, for the steps to slide the same way.
    @Published var forward = true
    /// A control on the Arrange step has been touched: its picture stops showing itself for good.
    @Published var arrangeTouched = false

    private var starts: [TourStep: Date] = [:]
    private let opened = Date()

    // Read only while drawing.
    var link = TourEased(0, duration: Look.beat)
    var size = TourEased(40)
    var distance = TourEased(1.4)
    var curve = TourEased(0)
    var layoutMix = TourEased(1, duration: Look.beat)
    var layoutFrom = ArrangeLayout.row
    var layoutTo = ArrangeLayout.row
    var screens = 2
    /// When everything needed became set up (seconds since the reference date), nil while something is to do.
    var completeSince: Double?

    init(step: TourStep = .welcome) {
        self.step = step
        starts[step] = Date()
    }

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    static func ready(_ state: AppState) -> Bool {
        Tour.ready(glassesConnected: state.glassesName != nil, screenRecordingAllowed: state.screenRecordingAllowed, capturing: state.capturing)
    }

    /// When [step] last came up: its picture's clock starts there.
    func start(of step: TourStep) -> Date { starts[step] ?? opened }

    /// Opens the tour at [step] with nothing moving.
    func open(at step: TourStep) {
        starts = [step: Date()]
        forward = true
        self.step = step
    }

    /// Moves to [to]. The direction is set first, so the step that leaves slides the right way.
    func go(_ to: TourStep) {
        guard to != step else { return }
        forward = to.rawValue > step.rawValue
        starts[to] = Date()
        let reduce: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let change: Animation = reduce ? Animation.linear(duration: Look.exit) : Animation.lookEnter()
        Task { @MainActor in
            withAnimation(change) { self.step = to }
        }
    }

    func next() { go(Tour.move(step, by: 1)) }
    func back() { go(Tour.move(step, by: -1)) }

    /// Takes everything as it is now, with nothing moving.
    func snap(store: SettingsStore, state: AppState) {
        let s = store.s
        link.snap(state.glassesName != nil ? 1 : 0)
        size.snap(s.widthDeg)
        distance.snap(s.distance)
        curve.snap(s.curve)
        layoutFrom = s.layout
        layoutTo = s.layout
        layoutMix.snap(1)
        screens = s.screens
        completeSince = TourModel.ready(state) ? 0 : nil
    }

    func setLayout(_ layout: ArrangeLayout) {
        guard layout != layoutTo else { return }
        layoutFrom = layoutTo
        layoutTo = layout
        layoutMix = TourEased(0, duration: Look.beat)
        layoutMix.set(1, now: TourModel.now())
    }

    /// The first touch of a control on the Arrange step: the picture goes from where its own demonstration had got
    /// to, to the Space's real values, and follows them from then on.
    func touchArrange() {
        guard !arrangeTouched else { return }
        let now: Double = TourModel.now()
        let ghost = TourScenes.arrangeGhost(Date().timeIntervalSince(start(of: .arrange)))
        let realSize: Double = size.to
        let realDistance: Double = distance.to
        let realCurve: Double = curve.to
        size = TourEased(ghost.sizeDeg)
        size.set(realSize, now: now)
        distance = TourEased(ghost.distance)
        distance.set(realDistance, now: now)
        curve = TourEased(ghost.curve)
        curve.set(realCurve, now: now)
        arrangeTouched = true
    }

    /// What a moving picture needs, [t] seconds after its step came up.
    func input(t: Double, now: Double) -> TourSceneInput {
        var input = TourSceneInput()
        input.link = link.value(now)
        if let since = completeSince {
            input.completeFor = max(min(t, now - since), 0)
        }
        input.arrange = TourArrangeInput(
            sizeDeg: size.value(now),
            distance: distance.value(now),
            curve: curve.value(now),
            from: layoutFrom,
            to: layoutTo,
            mix: layoutMix.value(now),
            screens: screens,
            ghost: !arrangeTouched
        )
        return input
    }

    /// What a still picture needs: everything as it is, nothing on its way.
    static func stillInput(store: SettingsStore, state: AppState, t: Double, touched: Bool) -> TourSceneInput {
        let s = store.s
        var input = TourSceneInput()
        input.link = state.glassesName != nil ? 1 : 0
        input.completeFor = ready(state) ? t : nil
        input.arrange = TourArrangeInput(
            sizeDeg: s.widthDeg,
            distance: s.distance,
            curve: s.curve,
            from: s.layout,
            to: s.layout,
            mix: 1,
            screens: s.screens,
            ghost: !touched
        )
        return input
    }
}

/// The tour. [fixedTime] freezes every picture at that second (for stills rendered to files); [reduceMotion]
/// overrides the Mac's own Reduce Motion setting.
@MainActor
struct TourScreen: View {
    @ObservedObject var model: TourModel
    let store: SettingsStore
    let state: AppState
    let actions: TourActionsRef
    let fixedTime: Double?
    let reduceMotion: Bool?
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(model: TourModel, store: SettingsStore, state: AppState, actions: TourActionsRef, fixedTime: Double? = nil, reduceMotion: Bool? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.state = state
        self.actions = actions
        self.fixedTime = fixedTime
        self.reduceMotion = reduceMotion
        self.onClose = onClose
    }

    /// Stills and plain fades: the Mac's Reduce Motion, or a still being rendered.
    private var reduced: Bool { reduceMotion ?? systemReduceMotion }

    var body: some View {
        GeometryReader { geo in
            let pictureW: CGFloat = (geo.size.width * 0.55).rounded()
            let wordsW: CGFloat = max(geo.size.width - pictureW, 0)
            HStack(spacing: 0) {
                pictureColumn
                    .frame(width: pictureW, height: geo.size.height)
                    .clipped()
                wordsColumn
                    .frame(width: wordsW, height: geo.size.height)
            }
        }
        .background(Color.lookPage)
        .background {
            TourSync(model: model, store: store, state: state)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, ColorScheme.dark)
    }

    /// A step arriving fades in over 120 ms and slides 16 points over 280 ms; the one leaving fades and slides the
    /// other way in 160 ms. With Reduce Motion, a plain fade.
    private var stepTransition: AnyTransition {
        if reduced { return AnyTransition.opacity }
        let distance: CGFloat = model.forward ? 16 : -16
        let fadeIn = AnyTransition.opacity.animation(Animation.lookEnter(Look.quick))
        let slideIn = AnyTransition.offset(x: distance, y: 0).animation(Animation.lookEnter(Look.enter))
        let fadeOut = AnyTransition.opacity.animation(Animation.lookExit(Look.exit))
        let slideOut = AnyTransition.offset(x: -distance, y: 0).animation(Animation.lookExit(Look.exit))
        return AnyTransition.asymmetric(insertion: fadeIn.combined(with: slideIn), removal: fadeOut.combined(with: slideOut))
    }

    private var pictureColumn: some View {
        ZStack {
            TourPicture(step: model.step, model: model, store: store, state: state, reduced: reduced, fixedTime: fixedTime)
                .tourArrive(0, reduced)
                .id(model.step)
                .transition(stepTransition)
        }
    }

    private var wordsColumn: some View {
        VStack(spacing: 0) {
            // The window's title bar is see-through and over the content; the bar sits below it.
            TourTopBar(step: model.step, reduced: reduced, onSkip: onClose)
                .padding(.top, 30)
                .padding(.leading, 28)
                .padding(.trailing, 16)
            ZStack(alignment: .topLeading) {
                wordsPage
                    .id(model.step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            TourBottomBar(step: model.step, onBack: { model.back() }, onNext: { advance() })
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 22)
        }
    }

    private func advance() {
        if Tour.isLast(model.step) {
            onClose()
        } else {
            model.next()
        }
    }

    /// The words scroll if a step is ever taller than the window. A still is drawn without the scroll view, which a
    /// picture rendered to a file cannot show.
    @ViewBuilder
    private var wordsPage: some View {
        if fixedTime != nil {
            words.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical) {
                words
            }
        }
    }

    private var words: some View {
        TourWords(step: model.step, model: model, store: store, state: state, actions: actions, reduced: reduced, fixedTime: fixedTime)
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keeps the pictures' values in step with the glasses and the settings, whichever step is showing. Draws nothing.
@MainActor
struct TourSync: View {
    @ObservedObject var model: TourModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .onAppear { model.snap(store: store, state: state) }
            .onChange(of: state.glassesName != nil) { _, connected in
                model.link.set(connected ? 1 : 0, now: TourModel.now())
            }
            .onChange(of: TourModel.ready(state)) { _, ready in
                model.completeSince = ready ? TourModel.now() : nil
            }
            .onChange(of: store.s.widthDeg) { _, value in
                model.size.set(value, now: TourModel.now())
            }
            .onChange(of: store.s.distance) { _, value in
                model.distance.set(value, now: TourModel.now())
            }
            .onChange(of: store.s.curve) { _, value in
                model.curve.set(value, now: TourModel.now())
            }
            .onChange(of: store.s.layout) { _, value in
                model.setLayout(value)
            }
            .onChange(of: store.s.screens) { _, value in
                model.screens = value
            }
    }
}

/// One step's picture: a Canvas drawn from the scene clock (seconds since the step came up). With Reduce Motion the
/// clock stays at the step's poster second, the moment that shows the picture's point.
@MainActor
struct TourPicture: View {
    let step: TourStep
    @ObservedObject var model: TourModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let reduced: Bool
    let fixedTime: Double?

    private var frozen: Double? {
        if let fixedTime { return fixedTime }
        return reduced ? Tour.poster(step) : nil
    }

    var body: some View {
        picture
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(TourCopy.picture(step, connected: state.glassesName != nil, ready: TourModel.ready(state))))
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private var picture: some View {
        if let time = frozen {
            canvas(time, TourModel.stillInput(store: store, state: state, t: time, touched: model.arrangeTouched))
        } else {
            TimelineView(.animation) { timeline in
                live(timeline.date)
            }
        }
    }

    private func live(_ date: Date) -> some View {
        let t: Double = date.timeIntervalSince(model.start(of: step))
        let now: Double = date.timeIntervalSinceReferenceDate
        return canvas(t, model.input(t: t, now: now))
    }

    private func canvas(_ t: Double, _ input: TourSceneInput) -> some View {
        let shown: TourStep = step
        return Canvas { context, size in
            TourScenes.draw(shown, context, size, t: t, input: input)
        }
    }
}

/// Eight segments that fill with the accent as the tour goes on, and Skip.
@MainActor
struct TourTopBar: View {
    let step: TourStep
    let reduced: Bool
    let onSkip: () -> Void

    var body: some View {
        // The last step ends with Done; Skip would only say the same.
        let last: Bool = Tour.isLast(step)
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Tour.steps, id: \.rawValue) { item in
                    TourSegment(filled: item.rawValue <= step.rawValue, reduced: reduced)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(TourCopy.stepOf(step)))
            Button(TourCopy.skip, action: onSkip)
                .buttonStyle(TourQuietStyle())
                .opacity(last ? 0 : 1)
                .disabled(last)
                .accessibilityHidden(last)
        }
        .frame(height: 30)
    }
}

@MainActor
struct TourSegment: View {
    let filled: Bool
    let reduced: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.lookRim)
            Capsule().fill(Color.lookAccent)
                .scaleEffect(x: filled ? 1 : 0, y: 1, anchor: .leading)
        }
        .frame(height: 3)
        .frame(maxWidth: .infinity)
        .clipShape(Capsule())
        .animation(reduced ? nil : Animation.lookEnter(), value: filled)
    }
}

/// Back, outlined and hidden on the first step; Next, or Done on the last, filled with the accent.
@MainActor
struct TourBottomBar: View {
    let step: TourStep
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if !Tour.isFirst(step) {
                Button(TourCopy.back, action: onBack)
                    .buttonStyle(TourPillStyle(primary: false, height: 40, minWidth: 88))
            }
            Spacer(minLength: 0)
            Button(Tour.isLast(step) ? TourCopy.finish : TourCopy.next, action: onNext)
                .buttonStyle(TourPillStyle(primary: true, height: 40, minWidth: 132))
        }
    }
}
