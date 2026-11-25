import Foundation
import PocketXRCore
import SwiftUI

// The live picture of the Space at the top of the Space pane: the screens as glass slabs on their arc around a small
// head, seen from above and a little behind, with the field of view as a wedge of light that swings with the head.
// Also the head gauge of the Head tracking pane. Both are drawn in a Canvas from the same numbers the glasses get.

/// How the settings' numbers are written for people.
enum SettingsFormat {
    static func degrees(_ v: Double) -> String { "\(Int(v.rounded()))°" }
    static func metres(_ v: Double) -> String { String(format: "%.1f m", v) }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
    static func millimetres(_ v: Double) -> String { "\(Int(v.rounded())) mm" }
    static func milliseconds(_ v: Double) -> String { "\(Int(v.rounded())) ms" }

    /// "Flat" at 0, else how far towards the strongest curve.
    static func curve(_ v: Double) -> String {
        let top: Double = SpaceSettings.curveRange.upperBound
        if v <= 0.0001 || top <= 0 { return "Flat" }
        return "\(Int((v / top * 100).rounded())) %"
    }

    /// "Off" at 0, else a percentage.
    static func glow(_ v: Double) -> String {
        v <= 0.0001 ? "Off" : percent(v)
    }

    static func signedDegrees(_ v: Double) -> String {
        String(format: "%+.1f°", v)
    }
}

/// A point or direction in the Space: x right, y up, z back (forward is -z), metres.
struct SettingsVec {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    func plus(_ o: SettingsVec) -> SettingsVec { SettingsVec(x + o.x, y + o.y, z + o.z) }
    func minus(_ o: SettingsVec) -> SettingsVec { SettingsVec(x - o.x, y - o.y, z - o.z) }
    func times(_ k: Double) -> SettingsVec { SettingsVec(x * k, y * k, z * k) }
    func dot(_ o: SettingsVec) -> Double { x * o.x + y * o.y + z * o.z }

    func cross(_ o: SettingsVec) -> SettingsVec {
        SettingsVec(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    var unit: SettingsVec {
        let l: Double = (x * x + y * y + z * z).squareRoot()
        return l > 1e-9 ? times(1 / l) : SettingsVec(0, 0, -1)
    }
}

/// The preview's camera: above and behind the head, looking down at the screens.
struct SettingsPreviewCamera {
    let position: SettingsVec
    let right: SettingsVec
    let up: SettingsVec
    let forward: SettingsVec

    /// [reach] is how far the furthest screen is; the camera backs off as the screens do, but less, so far screens
    /// still look further away.
    init(reach: Double) {
        let rho: Double = 1.4 * pow(max(reach, 0.3) / 1.4, 0.85)
        let pos = SettingsVec(0, 1.15 * rho, 1.55 * rho)
        let target = SettingsVec(0, 0.02 * rho, -0.55 * rho)
        let f: SettingsVec = target.minus(pos).unit
        let r: SettingsVec = f.cross(SettingsVec(0, 1, 0)).unit
        position = pos
        forward = f
        right = r
        up = r.cross(f).unit
    }

    /// Where a point lands for a focal length of 1 (x right, y up), nil when it is behind the camera.
    func flat(_ p: SettingsVec) -> SettingsFlat? {
        let v: SettingsVec = p.minus(position)
        let depth: Double = v.dot(forward)
        guard depth > 0.08 else { return nil }
        return SettingsFlat(x: v.dot(right) / depth, y: v.dot(up) / depth, depth: depth)
    }
}

struct SettingsFlat {
    var x: Double
    var y: Double
    var depth: Double
}

/// One screen as a strip across its width: flat, or bent round the head.
struct SettingsPreviewSlab {
    var top: [SettingsVec]
    var bottom: [SettingsVec]
    var centre: SettingsVec
    var focused: Bool

    init(_ p: PanelPlacement, focused: Bool) {
        let yaw: Double = p.yawDeg * Double.pi / 180
        let pitch: Double = p.pitchDeg * Double.pi / 180
        let d: Double = p.distance
        let dir = SettingsVec(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
        let right = SettingsVec(cos(yaw), 0, -sin(yaw))
        let up = SettingsVec(sin(yaw) * sin(pitch), cos(pitch), cos(yaw) * sin(pitch))
        let mid: SettingsVec = dir.times(d)
        let halfWidth: Double = min(max(p.widthDeg, 1), 170) * Double.pi / 360
        let w: Double = 2 * d * tan(halfWidth)
        let h: Double = w / max(p.aspect, 0.1)
        let bent: Bool = p.curve > 0.001
        let pieces: Int = bent ? 14 : 1
        var t = [SettingsVec]()
        var b = [SettingsVec]()
        for i in 0...pieces {
            let u: Double = Double(i) / Double(pieces) - 0.5
            let point: SettingsVec
            if bent {
                // On a circle of radius distance / curve that touches the flat screen's middle and bends towards the head.
                let radius: Double = d / p.curve
                let sweep: Double = min(w / radius, 3.0)
                let a: Double = u * sweep
                let along: SettingsVec = right.times(radius * sin(a))
                let towards: SettingsVec = dir.times(-radius * (1 - cos(a)))
                point = mid.plus(along).plus(towards)
            } else {
                point = mid.plus(right.times(u * w))
            }
            t.append(point.plus(up.times(h / 2)))
            b.append(point.minus(up.times(h / 2)))
        }
        top = t
        bottom = b
        centre = mid
        self.focused = focused
    }
}

/// Everything the preview draws, worked out once per frame.
struct SettingsSpaceDrawing {
    let placements: [PanelPlacement]
    let headYawDeg: Double
    let tracking: Bool
    let glow: Color
    let glowAmount: Double

    /// Half of the glasses' field of view across, degrees (38 degrees up and down at 16:9).
    static let halfFieldDeg: Double = 31.5

    private var reach: Double {
        let far: Double = placements.map { $0.distance }.max() ?? SpaceLayout.defaultDistance
        return max(far, 0.3)
    }

    /// The screen the head points at, if any.
    private var focusedIndex: Int? {
        var best: Int? = nil
        var bestOff: Double = 1e9
        for (i, p) in placements.enumerated() {
            var off: Double = (p.yawDeg - headYawDeg).truncatingRemainder(dividingBy: 360)
            if off > 180 { off -= 360 }
            if off < -180 { off += 360 }
            let a: Double = abs(off)
            if a <= p.widthDeg / 2 + 1, a < bestOff {
                best = i
                bestOff = a
            }
        }
        return best
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        let camera = SettingsPreviewCamera(reach: reach)
        let focus: Int? = focusedIndex
        var slabs = [SettingsPreviewSlab]()
        for (i, p) in placements.enumerated() {
            slabs.append(SettingsPreviewSlab(p, focused: focus == i))
        }
        let fit: SettingsPreviewFit = SettingsPreviewFit(camera: camera, slabs: slabs, size: size)
        drawRings(&context, camera, fit)
        drawField(&context, camera, fit)
        let ordered: [SettingsPreviewSlab] = slabs.sorted { a, b in
            a.centre.minus(camera.position).dot(camera.forward) > b.centre.minus(camera.position).dot(camera.forward)
        }
        for slab in ordered {
            drawSlab(&context, camera, fit, slab)
        }
        drawHead(&context, camera, fit)
    }

    // A ring on the floor of the picture at each metre from the head, so distance can be read.
    private func drawRings(_ context: inout GraphicsContext, _ camera: SettingsPreviewCamera, _ fit: SettingsPreviewFit) {
        let count: Int = min(Int(reach.rounded(.up)), 6)
        guard count >= 1 else { return }
        for metre in 1...count {
            let r: Double = Double(metre)
            var path = Path()
            var started: Bool = false
            for i in 0...72 {
                let a: Double = Double(i) * Double.pi / 36
                let p = SettingsVec(r * sin(a), 0, -r * cos(a))
                if let f = camera.flat(p) {
                    let point: CGPoint = fit.point(f)
                    if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                } else {
                    started = false
                }
            }
            context.stroke(path, with: .color(Color.white.opacity(0.07)), lineWidth: 1)
            let labelAt = SettingsVec(r * sin(1.15), 0, -r * cos(1.15))
            if let f = camera.flat(labelAt) {
                let text: Text = Text("\(metre) m")
                    .font(Font.system(size: 10, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.32))
                let at: CGPoint = fit.point(f)
                context.draw(text, at: CGPoint(x: at.x + 12, y: at.y))
            }
        }
    }

    // The field of view: a wedge of light from the head, turned with it while tracking.
    private func drawField(_ context: inout GraphicsContext, _ camera: SettingsPreviewCamera, _ fit: SettingsPreviewFit) {
        let yaw: Double = (tracking ? headYawDeg : 0) * Double.pi / 180
        let half: Double = Self.halfFieldDeg * Double.pi / 180
        let length: Double = reach * 1.08
        guard let origin = camera.flat(SettingsVec(0, 0, 0)) else { return }
        let start: CGPoint = fit.point(origin)
        var path = Path()
        path.move(to: start)
        var tip: CGPoint = start
        for i in 0...16 {
            let a: Double = yaw - half + 2 * half * Double(i) / 16
            // Left positive: a turn to the left moves the wedge towards -x.
            let p = SettingsVec(-length * sin(a), 0, -length * cos(a))
            guard let f = camera.flat(p) else { continue }
            let point: CGPoint = fit.point(f)
            path.addLine(to: point)
            if i == 8 { tip = point }
        }
        path.closeSubpath()
        let strength: Double = tracking ? 1 : 0.55
        let gradient = Gradient(colors: [
            Color.lookAccent.opacity(0.26 * strength),
            Color.lookAccent.opacity(0.03 * strength),
        ])
        context.fill(path, with: .linearGradient(gradient, startPoint: start, endPoint: tip))
        context.stroke(path, with: .color(Color.lookAccent.opacity(0.22 * strength)), lineWidth: 1)
    }

    private func drawSlab(_ context: inout GraphicsContext, _ camera: SettingsPreviewCamera, _ fit: SettingsPreviewFit,
                          _ slab: SettingsPreviewSlab) {
        var topPoints = [CGPoint]()
        var bottomPoints = [CGPoint]()
        for v in slab.top {
            guard let f = camera.flat(v) else { return }
            topPoints.append(fit.point(f))
        }
        for v in slab.bottom {
            guard let f = camera.flat(v) else { return }
            bottomPoints.append(fit.point(f))
        }
        guard let firstTop = topPoints.first, let lastTop = topPoints.last,
              let firstBottom = bottomPoints.first, let lastBottom = bottomPoints.last else { return }
        var path = Path()
        path.move(to: firstTop)
        for p in topPoints.dropFirst() { path.addLine(to: p) }
        for p in bottomPoints.reversed() { path.addLine(to: p) }
        path.closeSubpath()

        let midTop = CGPoint(x: (firstTop.x + lastTop.x) / 2, y: (firstTop.y + lastTop.y) / 2)
        let midBottom = CGPoint(x: (firstBottom.x + lastBottom.x) / 2, y: (firstBottom.y + lastBottom.y) / 2)
        let glass = Gradient(colors: [Look.glassTop.color.opacity(0.94), Look.glassBottom.color.opacity(0.94)])
        context.fill(path, with: .linearGradient(glass, startPoint: midTop, endPoint: midBottom))

        // A line of light along the top edge, as glass catches it.
        var edge = Path()
        edge.move(to: firstTop)
        for p in topPoints.dropFirst() { edge.addLine(to: p) }
        context.stroke(edge, with: .color(Color.white.opacity(0.30)), lineWidth: 1)

        let lit: Bool = slab.focused && glowAmount > 0.0001
        if lit {
            context.stroke(path, with: .color(glow.opacity(0.22 * glowAmount)), lineWidth: 6)
            context.stroke(path, with: .color(glow.opacity(0.35 + 0.6 * glowAmount)), lineWidth: 1.5)
        } else {
            let rim: Color = slab.focused ? Color.lookRimFocus : Color.lookRim
            context.stroke(path, with: .color(rim), lineWidth: 1)
        }
    }

    // The head: a small disc with the glasses as a bar of accent across its front.
    private func drawHead(_ context: inout GraphicsContext, _ camera: SettingsPreviewCamera, _ fit: SettingsPreviewFit) {
        guard let origin = camera.flat(SettingsVec(0, 0, 0)) else { return }
        let centre: CGPoint = fit.point(origin)
        let radius: CGFloat = CGFloat(min(max(fit.focal * 0.10 / origin.depth, 5), 13))
        let disc = CGRect(x: centre.x - radius, y: centre.y - radius * 0.82, width: radius * 2, height: radius * 1.64)
        context.fill(Path(ellipseIn: disc), with: .color(Look.control.color))
        context.stroke(Path(ellipseIn: disc), with: .color(Color.lookRimFocus), lineWidth: 1)

        let yaw: Double = (tracking ? headYawDeg : 0) * Double.pi / 180
        let reachOut: Double = Double(radius) / max(fit.focal, 1) * origin.depth
        let front = SettingsVec(-reachOut * sin(yaw), 0, -reachOut * cos(yaw))
        let side = SettingsVec(cos(yaw), 0, -sin(yaw)).times(reachOut * 0.95)
        guard let a = camera.flat(front.minus(side)), let b = camera.flat(front.plus(side)) else { return }
        var bar = Path()
        bar.move(to: fit.point(a))
        bar.addLine(to: fit.point(b))
        let style = StrokeStyle(lineWidth: 3, lineCap: .round)
        context.stroke(bar, with: .color(Color.lookAccent.opacity(0.30)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        context.stroke(bar, with: .color(tracking ? Color.lookHeld : Color.lookAccent), style: style)
    }
}

/// The scale and place that fit the whole Space into the picture, never larger than a comfortable size.
struct SettingsPreviewFit {
    let focal: Double
    let cx: Double
    let cy: Double

    init(camera: SettingsPreviewCamera, slabs: [SettingsPreviewSlab], size: CGSize) {
        var maxX: Double = 0.05
        var top: Double = 0
        var bottom: Double = 0
        var first: Bool = true
        var points = [SettingsVec]()
        points.append(SettingsVec(0, 0, 0))
        for s in slabs {
            points.append(contentsOf: s.top)
            points.append(contentsOf: s.bottom)
        }
        for p in points {
            guard let f = camera.flat(p) else { continue }
            maxX = max(maxX, abs(f.x))
            if first {
                top = f.y
                bottom = f.y
                first = false
            } else {
                top = max(top, f.y)
                bottom = min(bottom, f.y)
            }
        }
        let w: Double = Double(size.width)
        let h: Double = Double(size.height)
        let marginX: Double = 28
        let marginTop: Double = 30
        let marginBottom: Double = 26
        let spanY: Double = max(top - bottom, 0.05)
        let fitX: Double = (w - 2 * marginX) / (2 * maxX)
        let fitY: Double = (h - marginTop - marginBottom) / spanY
        let cap: Double = h * 2.2
        let f: Double = max(min(cap, min(fitX, fitY)), 1)
        focal = f
        cx = w / 2
        // The Space's top and bottom sit evenly inside the margins.
        let free: Double = (h - marginTop - marginBottom) - f * spanY
        cy = marginTop + free / 2 + f * top
    }

    func point(_ f: SettingsFlat) -> CGPoint {
        CGPoint(x: cx + focal * f.x, y: cy - focal * f.y)
    }
}

/// The picture itself. Size, distance and curve are animatable, so the slabs glide as the sliders move.
struct SettingsSpaceCanvas: View, Animatable {
    var widthDeg: Double
    var distance: Double
    var curve: Double
    var layout: ArrangeLayout
    var screens: Int
    var headYawDeg: Double
    var tracking: Bool
    var glow: Color
    var glowAmount: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(widthDeg, AnimatablePair(distance, curve)) }
        set {
            widthDeg = newValue.first
            distance = newValue.second.first
            curve = newValue.second.second
        }
    }

    private var drawing: SettingsSpaceDrawing {
        let count: Int = min(max(screens, 1), ScreenLimit.most)
        let aspects: [Double] = Array(repeating: 16.0 / 9.0, count: count)
        let placements: [PanelPlacement] = SpaceLayout.arrange(
            layout: layout,
            aspects: aspects,
            widthDeg: widthDeg,
            distance: distance,
            curve: max(curve, 0)
        )
        return SettingsSpaceDrawing(
            placements: placements,
            headYawDeg: headYawDeg,
            tracking: tracking,
            glow: glow,
            glowAmount: glowAmount
        )
    }

    var body: some View {
        let d: SettingsSpaceDrawing = drawing
        return Canvas { context, size in
            d.draw(in: &context, size: size)
        }
    }
}

/// The preview card: the centrepiece of the Space pane.
struct SettingsSpacePreview: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: String {
        let s: SpaceSettings = store.s
        let screens: String = s.screens == 1 ? "1 screen" : "\(s.screens) screens"
        return "\(screens) · \(SettingsFormat.degrees(s.widthDeg)) wide · \(SettingsFormat.metres(s.distance)) away"
    }

    private var canvas: some View {
        let s: SpaceSettings = store.s
        let motion: Animation? = reduceMotion ? nil : Animation.lookEnter()
        return SettingsSpaceCanvas(
            widthDeg: s.widthDeg,
            distance: s.distance,
            curve: s.curve,
            layout: s.layout,
            screens: s.screens,
            headYawDeg: state.yawDeg,
            tracking: state.trackingOn && s.headTracking,
            glow: s.glowColor.color.color,
            glowAmount: s.glow
        )
        .animation(motion, value: s.widthDeg)
        .animation(motion, value: s.distance)
        .animation(motion, value: s.curve)
    }

    private var caption: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(summary)
                .font(Font.system(size: 12.5, weight: .regular).monospacedDigit())
                .foregroundColor(Color.lookInk2)
            Spacer(minLength: 8)
            SettingsChip(state.trackingOn ? "Follows your head" : "Head tracking is off", lit: state.trackingOn)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Look.pad.color, Color.lookPage],
                startPoint: .top,
                endPoint: .bottom
            )
            canvas
            caption
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.lookRim, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Your Space, seen from above"))
        .accessibilityValue(Text(summary))
    }
}

// MARK: head gauge

/// Where the head points: a horizon that drops as you look up, and a ring of marks that turns with your head, the
/// recentred forward marked in the accent.
struct SettingsHeadGauge: View {
    let yawDeg: Double
    let pitchDeg: Double
    let live: Bool

    var body: some View {
        let yaw: Double = yawDeg
        let pitch: Double = pitchDeg
        let on: Bool = live
        return Canvas { context, size in
            SettingsHeadGauge.draw(&context, size: size, yawDeg: yaw, pitchDeg: pitch, live: on)
        }
        .frame(width: 112, height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Head direction"))
        .accessibilityValue(Text("Turned \(SettingsFormat.signedDegrees(yawDeg)), tilted \(SettingsFormat.signedDegrees(pitchDeg))"))
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize, yawDeg: Double, pitchDeg: Double, live: Bool) {
        let side: CGFloat = min(size.width, size.height)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer: CGFloat = side / 2 - 2
        let inner: CGFloat = outer - 12
        let face = CGRect(x: centre.x - inner, y: centre.y - inner, width: inner * 2, height: inner * 2)
        let strength: Double = live ? 1 : 0.4

        // The horizon, inside the face.
        var clipped: GraphicsContext = context
        clipped.clip(to: Path(ellipseIn: face))
        clipped.fill(Path(face), with: .color(Look.pad.color))
        let limited: Double = min(max(pitchDeg, -60), 60)
        let drop: CGFloat = CGFloat(limited / 60) * inner
        let horizonY: CGFloat = centre.y + drop
        let ground = CGRect(x: face.minX, y: horizonY, width: face.width, height: face.height * 2)
        clipped.fill(Path(ground), with: .color(Color.lookAccent.opacity(0.14 * strength)))
        var horizon = Path()
        horizon.move(to: CGPoint(x: face.minX, y: horizonY))
        horizon.addLine(to: CGPoint(x: face.maxX, y: horizonY))
        clipped.stroke(horizon, with: .color(Color.lookAccent.opacity(0.8 * strength)), lineWidth: 1.5)

        context.stroke(Path(ellipseIn: face), with: .color(Color.lookRim), lineWidth: 1)

        // The fixed mark: where the glasses point.
        var mark = Path()
        mark.move(to: CGPoint(x: centre.x - 14, y: centre.y))
        mark.addLine(to: CGPoint(x: centre.x - 5, y: centre.y))
        mark.move(to: CGPoint(x: centre.x + 5, y: centre.y))
        mark.addLine(to: CGPoint(x: centre.x + 14, y: centre.y))
        context.stroke(mark, with: .color(Color.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let dot = CGRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4)
        context.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.9)))

        // The ring of marks: forward sits at the top when you face it, and moves right as you turn left.
        for i in 0..<12 {
            let degrees: Double = Double(i) * 30 + yawDeg
            let a: Double = degrees * Double.pi / 180
            let sx: CGFloat = CGFloat(sin(a))
            let cy: CGFloat = CGFloat(cos(a))
            let isForward: Bool = i == 0
            let from: CGFloat = isForward ? inner + 2 : inner + 5
            let to: CGFloat = outer
            var tick = Path()
            tick.move(to: CGPoint(x: centre.x + sx * from, y: centre.y - cy * from))
            tick.addLine(to: CGPoint(x: centre.x + sx * to, y: centre.y - cy * to))
            let color: Color = isForward ? Color.lookAccent.opacity(strength) : Color.white.opacity(0.28)
            let width: CGFloat = isForward ? 3 : 1
            context.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }
}
