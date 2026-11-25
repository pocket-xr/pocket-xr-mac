import AppKit
import PocketXRCore
import SwiftUI

// The control panel's own two pictures. The map: every display as macOS has arranged it, each one a button that puts
// the pointer there. The pad: the floating screens as the wearer sees them, from the front, to drag about and resize.

// MARK: the map of displays

/// Which edge of the Mac's own screen the floating screens lie beyond.
enum ControlPanelEdge {
    case right, left, top, bottom

    var word: String {
        switch self {
        case .right: return "right"
        case .left: return "left"
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }
}

/// The displays drawn to scale inside a box: where each tile goes, and the arrow from the Mac's screen to the first
/// floating screen.
struct ControlPanelMapLayout {
    struct Placed: Identifiable {
        let tile: DisplayTile
        let rect: CGRect
        var id: Int { tile.id }
    }

    let placed: [Placed]
    let edge: ControlPanelEdge?
    /// The arrow's tail and tip, in the box.
    let arrow: (from: CGPoint, to: CGPoint)?

    init(tiles: [DisplayTile], size: CGSize) {
        var whole: CGRect = tiles.first?.frame ?? .zero
        for t in tiles.dropFirst() { whole = whole.union(t.frame) }
        let scale: CGFloat = min(
            size.width / max(whole.width, 1),
            size.height / max(whole.height, 1)
        )
        let dx: CGFloat = (size.width - whole.width * scale) / 2 - whole.minX * scale
        let dy: CGFloat = (size.height - whole.height * scale) / 2 - whole.minY * scale
        var out = [Placed]()
        for t in tiles {
            let r = CGRect(
                x: t.frame.minX * scale + dx,
                y: t.frame.minY * scale + dy,
                width: t.frame.width * scale,
                height: t.frame.height * scale
            )
            out.append(Placed(tile: t, rect: r))
        }
        placed = out

        let own: Placed? = out.first { $0.tile.isOwn }
        let first: Placed? = out.first { !$0.tile.isOwn }
        guard let o = own?.rect, let f = first?.rect else {
            edge = nil
            arrow = nil
            return
        }
        let e: ControlPanelEdge = Self.edge(from: o, to: f)
        edge = e
        // A short tail on the Mac's side, clear of its name, and the head well inside the floating screen.
        let tail: CGFloat = 5
        let reach: CGFloat = 16
        switch e {
        case .right, .left:
            // Where the two screens stand side by side, else level with the Mac's middle.
            let lo: CGFloat = max(o.minY, f.minY)
            let hi: CGFloat = min(o.maxY, f.maxY)
            let y: CGFloat = hi > lo ? (lo + hi) / 2 : o.midY
            let x: CGFloat = e == .right ? o.maxX : o.minX
            let sign: CGFloat = e == .right ? 1 : -1
            arrow = (from: CGPoint(x: x - sign * tail, y: y), to: CGPoint(x: x + sign * reach, y: y))
        case .top, .bottom:
            let lo: CGFloat = max(o.minX, f.minX)
            let hi: CGFloat = min(o.maxX, f.maxX)
            let x: CGFloat = hi > lo ? (lo + hi) / 2 : o.midX
            let y: CGFloat = e == .bottom ? o.maxY : o.minY
            let sign: CGFloat = e == .bottom ? 1 : -1
            arrow = (from: CGPoint(x: x, y: y - sign * tail), to: CGPoint(x: x, y: y + sign * reach))
        }
    }

    /// The Mac's edge that [f] lies beyond (y runs down, as displays are arranged).
    static func edge(from o: CGRect, to f: CGRect) -> ControlPanelEdge {
        let slack: CGFloat = 1
        if f.minX >= o.maxX - slack { return .right }
        if f.maxX <= o.minX + slack { return .left }
        if f.minY >= o.maxY - slack { return .bottom }
        if f.maxY <= o.minY + slack { return .top }
        let dx: CGFloat = f.midX - o.midX
        let dy: CGFloat = f.midY - o.midY
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .bottom : .top
    }

    /// The same question asked of the displays themselves, for the line of words under the map.
    static func edge(tiles: [DisplayTile]) -> ControlPanelEdge? {
        guard let o = tiles.first(where: { $0.isOwn }), let f = tiles.first(where: { !$0.isOwn }) else { return nil }
        return edge(from: o.frame, to: f.frame)
    }
}

/// "Your screens": the map, and one line that teaches how the pointer gets to a floating screen.
struct ControlPanelMapCard: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef

    /// One screen more or fewer, 1 to 6 (SpaceSettings.screensRange). Displays made twice in one session mislead capture, so with the glasses
    /// in, Pocket XR starts again to make the new set; with none in, the number is simply kept for next time.
    private func setScreens(_ n: Int) {
        let range = SpaceSettings.screensRange
        let to: Int = min(max(n, range.lowerBound), range.upperBound)
        guard to != store.s.screens else { return }
        store.s.screens = to
        if state.virtualScreens > 0 { actions.target?.restartApp() }
    }

    private var floating: Int {
        state.displayTiles.filter { !$0.isOwn }.count
    }

    private var rule: String {
        let n: Int = floating
        if n == 0 { return "Floating screens appear when your glasses are plugged in." }
        let edge: String = ControlPanelMapLayout.edge(tiles: state.displayTiles)?.word ?? "right"
        if n == 1 {
            return "Move the pointer off the \(edge) edge of this screen to reach your floating screen, or click it here."
        }
        return "Move the pointer off the \(edge) edge of this screen to reach your floating screens, or click one here."
    }

    var body: some View {
        SettingsCard("Your screens") {
            VStack(alignment: .leading, spacing: 8) {
                if !state.displayTiles.isEmpty {
                    ControlPanelMap(
                        tiles: state.displayTiles,
                        pointerOn: state.pointerScreen ?? -1,
                        actions: actions
                    )
                    .frame(height: ControlPanelMetrics.mapHeight)
                }
                Text(rule)
                    .font(Font.lookNote)
                    .foregroundColor(floating == 0 ? Color.lookInk3 : Color.lookInk2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(store.s.screens == 1 ? "1 floating screen" : "\(store.s.screens) floating screens")
                        .font(Font.lookLine)
                        .foregroundColor(Color.lookInk)
                    Text(state.virtualScreens > 0 ? "Changing it restarts Pocket XR" : "")
                        .font(Font.lookChip)
                        .foregroundColor(Color.lookInk3)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ControlPanelPairButton(
                        leftSymbol: "minus",
                        leftLabel: "Remove a screen",
                        rightSymbol: "plus",
                        rightLabel: "Add a screen",
                        left: { setScreens(store.s.screens - 1) },
                        right: { setScreens(store.s.screens + 1) }
                    )
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.top, state.displayTiles.isEmpty ? 10 : 12)
            .padding(.bottom, 10)
        }
    }
}

/// The tiles, to scale, with the arrow across the edge the pointer leaves by.
struct ControlPanelMap: View {
    let tiles: [DisplayTile]
    /// The tile the pointer is on: -1 the Mac's own screen.
    let pointerOn: Int
    let actions: SettingsActionsRef

    var body: some View {
        GeometryReader { geo in
            content(ControlPanelMapLayout(tiles: tiles, size: geo.size))
        }
    }

    private func content(_ layout: ControlPanelMapLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.placed) { p in
                ControlPanelMapTile(
                    tile: p.tile,
                    size: p.rect.size,
                    lit: p.tile.id == pointerOn,
                    action: { go(p.tile) }
                )
                .offset(x: p.rect.minX, y: p.rect.minY)
            }
            if let a = layout.arrow {
                ControlPanelArrow(from: a.from, to: a.to)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func go(_ tile: DisplayTile) {
        actions.target?.movePointer(toScreen: tile.isOwn ? nil : tile.id)
    }
}

/// One display on the map. The one the pointer is on is lit.
struct ControlPanelMapTile: View {
    let tile: DisplayTile
    let size: CGSize
    let lit: Bool
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    private var hint: String {
        tile.isOwn ? "Put the pointer on this Mac's screen" : "Put the pointer on \(tile.title)"
    }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(SettingsPressStyle())
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(tile.title))
            .accessibilityValue(Text(lit ? "The pointer is here" : ""))
            .accessibilityHint(Text(hint))
            .help(hint)
    }

    private var fill: LinearGradient {
        let top: Color = lit ? Color.lookAccent.opacity(0.30) : (hover ? Color.lookGlassHover : Look.glassTop.color)
        let bottom: Color = lit ? Color.lookAccent.opacity(0.16) : (hover ? Color.lookGlassHover : Look.glassBottom.color)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private var rim: Color {
        if focused { return Color.lookHeld }
        if lit { return Color.lookAccent }
        return hover ? Color.lookRimFocus : Color.lookRim
    }

    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(spacing: 3) {
            Text(tile.title)
                .font(Font.system(size: 11.5, weight: lit ? .medium : .regular))
                .foregroundColor(lit ? Color.lookInk : Color.lookInk2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if lit {
                Image(systemName: "cursorarrow")
                    .font(Font.system(size: 9, weight: .medium))
                    .foregroundColor(Color.lookHeld)
            }
        }
        .padding(.horizontal, 4)
        .frame(width: max(size.width - 4, 8), height: max(size.height - 4, 8))
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(rim, lineWidth: lit || focused ? 1.5 : 1))
        .padding(2)
        .contentShape(Rectangle())
        .animation(Animation.lookEnter(Look.quick), value: hover)
        .animation(Animation.lookEnter(), value: lit)
    }
}

/// A small arrow: a line with a head, in the colour of something held.
struct ControlPanelArrow: View {
    let from: CGPoint
    let to: CGPoint

    var body: some View {
        let a: CGPoint = from
        let b: CGPoint = to
        return Canvas { context, _ in
            let dx: CGFloat = b.x - a.x
            let dy: CGFloat = b.y - a.y
            let length: CGFloat = max((dx * dx + dy * dy).squareRoot(), 0.001)
            let ux: CGFloat = dx / length
            let uy: CGFloat = dy / length
            let head: CGFloat = 5
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            path.move(to: CGPoint(x: b.x - ux * head - uy * head, y: b.y - uy * head + ux * head))
            path.addLine(to: b)
            path.addLine(to: CGPoint(x: b.x - ux * head + uy * head, y: b.y - uy * head - ux * head))
            let line = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
            // A dark edge under it, so it reads across the tiles' rims.
            context.stroke(path, with: .color(Color.lookPage.opacity(0.85)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(Color.lookHeld), style: line)
        }
    }
}

// MARK: the pad

/// Degrees to points on the pad: straight ahead in the middle, left to the left, up at the top. The scale depends
/// only on how much the screens span, never on where they are, so a drag keeps one scale from start to end.
struct ControlPanelPadGeometry {
    let size: CGSize
    /// Points per degree.
    let scale: Double

    init(panels: [PanelPlacement], size: CGSize) {
        self.size = size
        let w: Double = Double(size.width)
        let h: Double = Double(size.height)
        var s: Double = h / ControlPanelMetrics.padPitchSpan
        if let p0 = panels.first {
            var yawLo: Double = p0.yawDeg - p0.widthDeg / 2
            var yawHi: Double = p0.yawDeg + p0.widthDeg / 2
            var pitchLo: Double = p0.pitchDeg - p0.heightDeg / 2
            var pitchHi: Double = p0.pitchDeg + p0.heightDeg / 2
            for p in panels.dropFirst() {
                let half: Double = p.heightDeg / 2
                yawLo = min(yawLo, p.yawDeg - p.widthDeg / 2)
                yawHi = max(yawHi, p.yawDeg + p.widthDeg / 2)
                pitchLo = min(pitchLo, p.pitchDeg - half)
                pitchHi = max(pitchHi, p.pitchDeg + half)
            }
            s = min(s, (w - 40) / max(yawHi - yawLo, 1), (h - 28) / max(pitchHi - pitchLo, 1))
        }
        scale = max(s, 0.2)
    }

    func rect(yawDeg: Double, pitchDeg: Double, widthDeg: Double, heightDeg: Double) -> CGRect {
        let cx: Double = Double(size.width) / 2 - yawDeg * scale
        let cy: Double = Double(size.height) / 2 - pitchDeg * scale
        let w: Double = widthDeg * scale
        let h: Double = heightDeg * scale
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

/// Everything the pad draws.
struct ControlPanelPadDrawing {
    let panels: [PanelPlacement]
    /// The floating screen the pointer is on, if any.
    let focused: Int?
    let headYawDeg: Double
    let headPitchDeg: Double
    let viewFovYDeg: Double
    let viewAspect: Double
    /// Glasses are plugged in, so there is a view to show.
    let showView: Bool
    let held: Bool

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        let g = ControlPanelPadGeometry(panels: panels, size: size)
        drawGround(&context, g)
        if showView { drawView(&context, g) }
        for (i, p) in panels.enumerated() {
            drawPanel(&context, g, p, index: i)
        }
    }

    // The horizon, a mark every 30 degrees along it, and a longer one straight ahead.
    private func drawGround(_ context: inout GraphicsContext, _ g: ControlPanelPadGeometry) {
        let midY: CGFloat = g.size.height / 2
        let midX: CGFloat = g.size.width / 2
        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: midY))
        horizon.addLine(to: CGPoint(x: g.size.width, y: midY))
        context.stroke(horizon, with: .color(Color.white.opacity(0.06)), lineWidth: 1)
        var ticks = Path()
        var step: Int = -6
        while step <= 6 {
            let x: CGFloat = midX - CGFloat(Double(step) * 30 * g.scale)
            let half: CGFloat = step == 0 ? 7 : 3
            if x > 4, x < g.size.width - 4 {
                ticks.move(to: CGPoint(x: x, y: midY - half))
                ticks.addLine(to: CGPoint(x: x, y: midY + half))
            }
            step += 1
        }
        context.stroke(ticks, with: .color(Color.white.opacity(0.14)), lineWidth: 1)
    }

    // What the glasses show now: a faint rounded rectangle where the head points.
    private func drawView(_ context: inout GraphicsContext, _ g: ControlPanelPadGeometry) {
        let fovY: Double = min(max(viewFovYDeg, 5), 120)
        // As wide as that height makes it on a flat picture of the given shape.
        let fovX: Double = 2 * atan(tan(fovY * Double.pi / 360) * max(viewAspect, 0.2)) * 180 / Double.pi
        let r: CGRect = g.rect(yawDeg: headYawDeg, pitchDeg: headPitchDeg, widthDeg: fovX, heightDeg: fovY)
        let shape = Path(roundedRect: r, cornerRadius: 9, style: .continuous)
        context.fill(shape, with: .color(Color.lookAccent.opacity(0.07)))
        context.stroke(shape, with: .color(Color.lookAccent.opacity(0.34)), lineWidth: 1)
        let label: Text = Text("Your view")
            .font(Font.system(size: 10, weight: .regular))
            .foregroundColor(Color.lookHeld.opacity(0.75))
        let y: CGFloat = r.maxY + 9 < g.size.height - 4 ? r.maxY + 9 : r.minY - 9
        context.draw(label, at: CGPoint(x: r.midX, y: y))
    }

    private func drawPanel(_ context: inout GraphicsContext, _ g: ControlPanelPadGeometry, _ p: PanelPlacement, index: Int) {
        let r: CGRect = g.rect(yawDeg: p.yawDeg, pitchDeg: p.pitchDeg, widthDeg: p.widthDeg, heightDeg: p.heightDeg)
        let radius: CGFloat = min(5, min(r.width, r.height) / 4)
        let shape = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
        let glass = Gradient(colors: [Look.glassTop.color.opacity(0.96), Look.glassBottom.color.opacity(0.96)])
        context.fill(shape, with: .linearGradient(glass, startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
        // A line of light along the top edge, as glass catches it.
        var edge = Path()
        edge.move(to: CGPoint(x: r.minX + radius, y: r.minY + 0.5))
        edge.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY + 0.5))
        context.stroke(edge, with: .color(Color.white.opacity(0.30)), lineWidth: 1)
        let lit: Bool = focused == index
        if held {
            context.stroke(shape, with: .color(Color.lookHeld.opacity(0.25)), lineWidth: 5)
            context.stroke(shape, with: .color(Color.lookHeld), lineWidth: 1.5)
        } else if lit {
            context.stroke(shape, with: .color(Color.lookAccent.opacity(0.22)), lineWidth: 5)
            context.stroke(shape, with: .color(Color.lookAccent.opacity(0.95)), lineWidth: 1.5)
        } else {
            context.stroke(shape, with: .color(Color.lookRimFocus), lineWidth: 1)
        }
        if r.width > 16, r.height > 14 {
            let number: Text = Text("\(index + 1)")
                .font(Font.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(lit || held ? Color.lookInk : Color.lookInk2)
            context.draw(number, at: CGPoint(x: r.midX, y: r.midY))
        }
    }
}

/// "Place": the pad, and Recentre under it.
struct ControlPanelPlaceCard: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef

    private var recentreKeys: String? {
        guard store.s.shortcuts else { return nil }
        return Shortcut.all.first { $0.id == "recentre" }?.keys
    }

    var body: some View {
        SettingsCard("Place") {
            ControlPanelPad(store: store, state: state, actions: actions)
                .frame(height: ControlPanelMetrics.padHeight)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            ControlPanelRecentreButton(keys: recentreKeys) { actions.target?.recentre() }
                .padding(12)
        }
    }
}

/// The pad itself. Drag moves the whole Space; a pinch or a scroll resizes it; the corners hold the same as buttons.
struct ControlPanelPad: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef
    @State private var lastDrag: CGSize = .zero
    @State private var dragging: Bool = false
    /// What a drag has hold of: one screen (its index), or all of them with nil. Decided where the drag starts.
    @State private var dragScreen: Int? = nil
    @State private var pinchFrom: Double? = nil
    @State private var hover: Bool = false
    @Environment(\.settingsStatic) private var isStatic

    private static let degreesPerScroll: Double = 0.12

    private var steady: Bool { state.steady }

    private var drawing: ControlPanelPadDrawing {
        ControlPanelPadDrawing(
            panels: state.panels,
            focused: state.pointerScreen,
            headYawDeg: state.yawDeg,
            headPitchDeg: state.pitchDeg,
            viewFovYDeg: state.viewFovYDeg,
            viewAspect: state.viewAspect,
            showView: state.glassesName != nil,
            held: dragging || pinchFrom != nil
        )
    }

    private var spoken: String {
        let n: Int = state.panels.count
        if n == 0 { return "No floating screens yet" }
        let screens: String = n == 1 ? "1 screen" : "\(n) screens"
        return "\(screens), each \(SettingsFormat.degrees(store.s.widthDeg)) wide"
    }

    var body: some View {
        GeometryReader { geo in
            surface(size: geo.size)
        }
        .onHover { hover = $0 }
    }

    private func surface(size: CGSize) -> some View {
        let d: ControlPanelPadDrawing = drawing
        let scale: Double = ControlPanelPadGeometry(panels: state.panels, size: size).scale
        return ZStack {
            LinearGradient(colors: [Look.pad.color, Color.lookPage], startPoint: .top, endPoint: .bottom)
            Canvas { context, canvasSize in
                d.draw(in: &context, size: canvasSize)
            }
            .opacity(steady ? 0.28 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Your floating screens, seen from the front"))
            .accessibilityValue(Text(spoken))
            if !isStatic {
                ControlPanelScrollCatcher(enabled: true) { dy in scrolled(dy) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            words
            lineUp
            corners
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(drag(scale: scale, size: size))
        .simultaneousGesture(pinch)
        .animation(Animation.lookEnter(Look.quick), value: dragging)
        .animation(Animation.lookInOut(), value: steady)
    }

    // The hint at the top, or what Steady mode means here.
    @ViewBuilder
    private var words: some View {
        if steady {
            Text("Steady mode: the glasses hold the picture. − and + change its size.")
                .font(Font.lookNote)
                .foregroundColor(Color.lookInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 250)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2, style: .continuous)
                        .fill(Color.lookCard.opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius + 2, style: .continuous)
                        .strokeBorder(Color.lookRim, lineWidth: 1)
                )
                .padding(.bottom, 26)
                .allowsHitTesting(false)
        } else {
            Text(hint)
                .font(Font.system(size: 12, weight: .regular))
                .foregroundColor(hover || dragging ? Color.lookInk : Color.lookInk2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .animation(Animation.lookEnter(Look.quick), value: hover)
        }
    }

    private var hint: String {
        if state.panels.isEmpty { return "Your floating screens will show here." }
        if state.panels.count == 1 { return "Drag to move. Pinch or scroll to resize." }
        return "Drag one screen, or beside them for all. Pinch to resize."
    }

    /// Shown once a screen has been moved by hand: puts every screen back in its place in the layout.
    @ViewBuilder
    private var lineUp: some View {
        if !steady && store.s.screensMoved {
            ControlPanelSmallButton("Line up") { actions.target?.resetScreenMoves() }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    // Size at the bottom left, distance at the bottom right.
    private var corners: some View {
        HStack(alignment: .center, spacing: 6) {
            ControlPanelPairButton(
                leftSymbol: "minus",
                leftLabel: "Smaller",
                rightSymbol: "plus",
                rightLabel: "Bigger",
                left: { actions.target?.adjust(.smaller) },
                right: { actions.target?.adjust(.bigger) }
            )
            Spacer(minLength: 8)
            // A flat picture has no nearer or further: in Steady mode only the size changes.
            Group {
                ControlPanelSmallButton("Nearer") { actions.target?.adjust(.nearer) }
                ControlPanelSmallButton("Further") { actions.target?.adjust(.further) }
            }
            .disabled(steady)
            .opacity(steady ? 0.4 : 1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The screen under a point of the pad, the topmost first, nil on the space around them.
    private func screen(at point: CGPoint, size: CGSize) -> Int? {
        let geometry = ControlPanelPadGeometry(panels: state.panels, size: size)
        for (i, p) in state.panels.enumerated().reversed() {
            let r: CGRect = geometry.rect(yawDeg: p.yawDeg, pitchDeg: p.pitchDeg, widthDeg: p.widthDeg, heightDeg: p.heightDeg)
            if r.insetBy(dx: -3, dy: -3).contains(point) { return i }
        }
        return nil
    }

    private func drag(scale: Double, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard !steady, scale > 0 else { return }
                // A drag that starts on a screen moves that screen; one that starts beside them moves them all.
                if !dragging { dragScreen = state.panels.count > 1 ? screen(at: g.startLocation, size: size) : nil }
                dragging = true
                let dx: Double = Double(g.translation.width - lastDrag.width)
                let dy: Double = Double(g.translation.height - lastDrag.height)
                lastDrag = g.translation
                // Yaw is left positive and pitch up positive; the pad's x runs right and its y down.
                if dx != 0 || dy != 0 {
                    if let one = dragScreen {
                        actions.target?.nudgeScreen(one, yawDeg: -dx / scale, pitchDeg: -dy / scale)
                    } else {
                        actions.target?.nudgeSpace(yawDeg: -dx / scale, pitchDeg: -dy / scale)
                    }
                }
            }
            .onEnded { _ in
                lastDrag = .zero
                dragging = false
                dragScreen = nil
            }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if steady {
                    let from: Double = pinchFrom ?? store.s.steadyZoom
                    if pinchFrom == nil { pinchFrom = from }
                    setSteadyZoom(from * Double(value))
                    return
                }
                let from: Double = pinchFrom ?? store.s.widthDeg
                if pinchFrom == nil { pinchFrom = from }
                setWidth(from * Double(value))
            }
            .onEnded { _ in pinchFrom = nil }
    }

    private func scrolled(_ dy: CGFloat) {
        if steady {
            setSteadyZoom(store.s.steadyZoom + Double(dy) * Self.degreesPerScroll / 40)
            return
        }
        setWidth(store.s.widthDeg + Double(dy) * Self.degreesPerScroll)
    }

    private func setSteadyZoom(_ wanted: Double) {
        let range: ClosedRange<Double> = SpaceSettings.steadyZoomRange
        let next: Double = min(max(wanted, range.lowerBound), range.upperBound)
        if next != store.s.steadyZoom { store.s.steadyZoom = next }
    }

    private func setWidth(_ wanted: Double) {
        let range: ClosedRange<Double> = SpaceSettings.widthRange
        let next: Double = min(max(wanted, range.lowerBound), range.upperBound)
        if next != store.s.widthDeg { store.s.widthDeg = next }
    }
}

// MARK: the pad's buttons

/// The panel's one main button, as wide as its card: "Recentre", with its shortcut at the right.
struct ControlPanelRecentreButton: View {
    let keys: String?
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(SettingsPressStyle())
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text("Recentre"))
            .accessibilityHint(Text(keys.map { "Shortcut: " + SettingsKeys.spoken($0) } ?? ""))
            .help("Bring the screens back in front of you")
    }

    private var face: some View {
        ZStack {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(Font.system(size: 12, weight: .medium))
                Text("Recentre")
                    .font(Font.lookButton)
            }
            if let keys {
                Text(keys)
                    .font(Font.system(size: 12, weight: .medium))
                    .opacity(0.62)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
            }
        }
        .foregroundColor(Color.lookPage)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(Capsule().fill(hover ? Color.lookHeld : Color.lookAccent))
        .overlay(Capsule().strokeBorder(Color.white, lineWidth: 2).opacity(focused ? 1 : 0))
        .contentShape(Capsule())
        .animation(Animation.lookEnter(Look.quick), value: hover)
    }
}

/// A small glass pill on the pad.
struct ControlPanelSmallButton: View {
    let title: String
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(SettingsPressStyle())
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hover = $0 }
            .accessibilityLabel(Text(title))
    }

    private var face: some View {
        Text(title)
            .font(Font.system(size: 12, weight: .medium))
            .foregroundColor(Color.lookInk)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(hover ? Color.lookGlassHover : Look.control.color.opacity(0.9)))
            .overlay(Capsule().strokeBorder(focused ? Color.lookAccent : (hover ? Color.lookRimFocus : Color.lookRim), lineWidth: focused ? 2 : 1))
            .contentShape(Capsule())
            .animation(Animation.lookEnter(Look.quick), value: hover)
    }
}

/// Two symbols in one pill: smaller and bigger.
struct ControlPanelPairButton: View {
    let leftSymbol: String
    let leftLabel: String
    let rightSymbol: String
    let rightLabel: String
    let left: () -> Void
    let right: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ControlPanelPairHalf(symbol: leftSymbol, label: leftLabel, action: left)
            Rectangle()
                .fill(Color.lookRim)
                .frame(width: 1, height: 14)
            ControlPanelPairHalf(symbol: rightSymbol, label: rightLabel, action: right)
        }
        .frame(height: 26)
        .background(Capsule().fill(Look.control.color.opacity(0.9)))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.lookRim, lineWidth: 1))
    }
}

struct ControlPanelPairHalf: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

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
            .font(Font.system(size: 11, weight: .semibold))
            .foregroundColor(focused ? Color.lookHeld : Color.lookInk)
            .frame(width: 32, height: 26)
            .background(Color.lookGlassHover.opacity(hover ? 1 : 0))
            .contentShape(Rectangle())
            .animation(Animation.lookEnter(Look.quick), value: hover)
    }
}

// MARK: scroll wheel

/// SwiftUI has no scroll-wheel gesture, so a clear AppKit view lies over the pad and watches the window's scroll
/// events: one over the pad resizes the screens and goes no further (the panel itself does not scroll under it).
/// Clicks and drags pass through it untouched.
struct ControlPanelScrollCatcher: NSViewRepresentable {
    let enabled: Bool
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ControlPanelScrollNSView {
        let v = ControlPanelScrollNSView()
        v.enabled = enabled
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ v: ControlPanelScrollNSView, context: Context) {
        v.enabled = enabled
        v.onScroll = onScroll
    }

    static func dismantleNSView(_ v: ControlPanelScrollNSView, coordinator: ()) {
        v.stopWatching()
    }
}

final class ControlPanelScrollNSView: NSView {
    var enabled: Bool = true
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatching()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.take(event) ? nil : event
        }
    }

    func stopWatching() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// True when the scroll was over the pad and has been used.
    private func take(_ event: NSEvent) -> Bool {
        guard enabled, let w = window, event.window === w, !isHiddenOrHasHiddenAncestor else { return false }
        let at: NSPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(at) else { return false }
        let dy: CGFloat = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        if dy != 0 { onScroll?(dy) }
        return true
    }
}
