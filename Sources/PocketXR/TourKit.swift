import PocketXRCore
import SwiftUI

// What the tour's pictures are drawn with (the Android app's TourKit.kt). Everything is "Light on glass": smoked glass
// with a hairline rim, one accent, depth shown with light and never shadow. The colours and motion times are Look's.
//
// All of the pictures' arithmetic is in Double (seconds, points, metres), and turned into CoreGraphics values only in
// the few drawing functions at the bottom of TourDraw.

/// A point of a picture, in the canvas's points.
struct TourPoint {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    var cg: CGPoint { CGPoint(x: x, y: y) }
}

/// A rectangle of a picture.
struct TourBox {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var centre: TourPoint { TourPoint(midX, midY) }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// The point ([u], [v]) of the box: 0, 0 its top left and 1, 1 its bottom right.
    func at(_ u: Double, _ v: Double) -> TourPoint { TourPoint(x + w * u, y + h * v) }

    /// The part of the box from ([u0], [v0]) to ([u1], [v1]).
    func part(_ u0: Double, _ v0: Double, _ u1: Double, _ v1: Double) -> TourBox {
        TourBox(x + w * u0, y + h * v0, w * (u1 - u0), h * (v1 - v0))
    }

    func inset(_ d: Double) -> TourBox { TourBox(x + d, y + d, max(w - 2 * d, 0), max(h - 2 * d, 0)) }
}

/// The pictures' colours, as numbers so they can be mixed and faded.
enum TourTone {
    static let accent = Look.accent
    static let accentDeep = Look.accentDeep
    static let held = Look.held
    static let ink = Look.ink
    static let ink2 = Look.ink2
    static let ink3 = Look.ink3
    static let rim = Look.rim
    static let rimFocus = Look.rimFocus
    static let page = Look.page
    static let pad = Look.pad
    static let glassTop = Look.glassTop
    static let glassBottom = Look.glassBottom
    static let glassRaised = Look.glassRaised
    static let control = Look.control
    static let media = Look.media
    static let white = LookColor(1, 1, 1)
    /// A lens with a picture in it.
    static let lens = LookColor(hex: 0x24365E)
    /// A small window on a screen: glass a step lighter than the screen it is on.
    static let window = LookColor(hex: 0x2F3850)
    /// A key's lower edge.
    static let keyEdge = LookColor(hex: 0x12151C)

    /// White at [alpha]: the ink of a sketch.
    static func tint(_ alpha: Double) -> LookColor { LookColor(1, 1, 1, alpha) }
}

/// Time and mixing for pictures drawn as a function of the seconds since they came up.
enum TourMath {
    enum Ease {
        /// Everything that arrives or moves.
        case enter
        /// Everything that leaves.
        case exit
        case inOut
        /// Slow drifting.
        case sine
        /// Only for a hold filling.
        case linear
    }

    static func ease(_ e: Ease, _ k: Double) -> Double {
        switch e {
        case .enter: return LookEase.enter(k)
        case .exit: return LookEase.exit(k)
        case .inOut: return LookEase.inOut(k)
        case .sine: return LookEase.sine(k)
        case .linear: return min(max(k, 0), 1)
        }
    }

    /// How far [t] is from [from] to [to], 0 to 1, eased.
    static func span(_ t: Double, _ from: Double, _ to: Double, _ e: Ease = .enter) -> Double {
        ease(e, LookEase.span(t, from, to))
    }

    static func mix(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    static func mixP(_ a: TourPoint, _ b: TourPoint, _ k: Double) -> TourPoint {
        TourPoint(mix(a.x, b.x, k), mix(a.y, b.y, k))
    }

    static func mixB(_ a: TourBox, _ b: TourBox, _ k: Double) -> TourBox {
        TourBox(mix(a.x, b.x, k), mix(a.y, b.y, k), mix(a.w, b.w, k), mix(a.h, b.h, k))
    }

    static func mixC(_ a: LookColor, _ b: LookColor, _ k: Double) -> LookColor {
        let c = min(max(k, 0), 1)
        return LookColor(mix(a.r, b.r, c), mix(a.g, b.g, c), mix(a.b, b.b, c), mix(a.a, b.a, c))
    }

    /// A one-off between [at] and [at] + [length]: its progress 0 to 1, or nil outside.
    static func burst(_ t: Double, _ at: Double, _ length: Double) -> Double? {
        guard length > 0 else { return nil }
        let k = (t - at) / length
        return (k >= 0 && k <= 1) ? k : nil
    }

    /// A one-off that rises and falls back, 0 outside: a press, an edge lighting as something crosses it.
    static func pulse(_ t: Double, _ at: Double, _ length: Double) -> Double {
        guard let k = burst(t, at, length) else { return 0 }
        return sin(Double.pi * k)
    }

    /// Fades a looping picture in at its start and out before [length], so the loop never jumps.
    static func loopAlpha(_ t: Double, _ length: Double, fadeIn: Double = Tour.loopFadeIn, fadeOut: Double = Tour.loopFadeOut) -> Double {
        span(t, 0, fadeIn) * (1 - span(t, length - fadeOut, length, .exit))
    }

    static func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180 }
}

// ---- the Space, seen through the glasses ----

/// The eye a picture is seen from: turned [yawDeg] to the right and [pitchDeg] up, standing [shiftX] metres to the
/// right, [back] metres behind the viewer's own place and [up] metres above it, drawing [focal] points at 1 m about
/// ([cx], [cy]).
struct TourCamera {
    var yawDeg: Double
    var focal: Double
    var cx: Double
    var cy: Double
    var shiftX: Double = 0
    var pitchDeg: Double = 0
    var back: Double = 0
    var up: Double = 0

    /// The canvas point of a place in the Space ([wx] metres right, [wy] up, [wz] ahead), or nil behind the eye.
    func project(_ wx: Double, _ wy: Double, _ wz: Double) -> TourPoint? {
        let c: Double = TourMath.radians(yawDeg)
        let p: Double = TourMath.radians(pitchDeg)
        let dx: Double = wx - shiftX
        let dy: Double = wy - up
        let dz: Double = wz + back
        let x: Double = dx * cos(c) - dz * sin(c)
        let z1: Double = dx * sin(c) + dz * cos(c)
        let z: Double = z1 * cos(p) + dy * sin(p)
        let y: Double = dy * cos(p) - z1 * sin(p)
        if z < 0.2 { return nil }
        return TourPoint(cx + focal * x / z, cy - focal * y / z)
    }

    /// How far ahead of the eye a place is (for drawing far things first).
    func depth(_ wx: Double, _ wy: Double, _ wz: Double) -> Double {
        let c: Double = TourMath.radians(yawDeg)
        let p: Double = TourMath.radians(pitchDeg)
        let z1: Double = (wx - shiftX) * sin(c) + (wz + back) * cos(c)
        return z1 * cos(p) + (wy - up) * sin(p)
    }
}

/// A screen in the Space: its middle [theta] degrees to the right at [r] metres and [y] metres up, [w] by [h] metres,
/// facing the viewer's place (as Pocket XR sets screens around you). [curve] bends it round the viewer: 0 flat, 1 an
/// arc centred on the viewer. [u0]...[v1] pick a part of it, so a small window on a screen is drawn the same way.
struct TourPanel {
    var theta: Double
    var y: Double
    var w: Double
    var h: Double
    var r: Double = 1.5
    var curve: Double = 0
    var u0: Double = 0
    var v0: Double = 0
    var u1: Double = 1
    var v1: Double = 1

    init(theta: Double, y: Double, w: Double, h: Double, r: Double = 1.5, curve: Double = 0) {
        self.theta = theta
        self.y = y
        self.w = w
        self.h = h
        self.r = r
        self.curve = curve
    }

    /// The part of this panel from ([a], [b]) to ([c], [d]) of what it shows now.
    func part(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> TourPanel {
        var p = self
        p.u0 = u0 + (u1 - u0) * a
        p.v0 = v0 + (v1 - v0) * b
        p.u1 = u0 + (u1 - u0) * c
        p.v1 = v0 + (v1 - v0) * d
        return p
    }

    /// Where ([u], [v]) of the panel is in the Space: metres right, up and ahead.
    func place(_ u: Double, _ v: Double) -> (x: Double, y: Double, z: Double) {
        let uu: Double = u0 + (u1 - u0) * u
        let vv: Double = v0 + (v1 - v0) * v
        let a: Double = TourMath.radians(theta)
        let along: Double = (uu - 0.5) * w
        var lx: Double = along
        var lz: Double = r
        if curve > 0.001 {
            let radius: Double = r / curve
            let phi: Double = along / radius
            lx = radius * sin(phi)
            lz = r - radius * (1 - cos(phi))
        }
        let wx: Double = lz * sin(a) + lx * cos(a)
        let wz: Double = lz * cos(a) - lx * sin(a)
        let wy: Double = y + (0.5 - vv) * h
        return (wx, wy, wz)
    }

    /// The canvas point of ([u], [v]) on the panel (0, 0 top left; 1, 1 bottom right), or nil behind the eye.
    func at(_ cam: TourCamera, _ u: Double, _ v: Double) -> TourPoint? {
        let p = place(u, v)
        return cam.project(p.x, p.y, p.z)
    }

    /// How far ahead of the eye the panel's middle is.
    func depth(_ cam: TourCamera) -> Double {
        let p = place(0.5, 0.5)
        return cam.depth(p.x, p.y, p.z)
    }

    /// The panel's outline with rounded corners ([radius] metres), or nil when any of it is behind the eye.
    func outline(_ cam: TourCamera, radius: Double = 0.035) -> Path? {
        let partW: Double = max(w * abs(u1 - u0), 0.0001)
        let partH: Double = max(h * abs(v1 - v0), 0.0001)
        let ru: Double = min(radius / partW, 0.5)
        let rv: Double = min(radius / partH, 0.5)
        // A bent panel's long edges are drawn as several short ones.
        let steps: Int = curve > 0.001 ? 12 : 1
        var top: [TourPoint] = []
        var bottom: [TourPoint] = []
        for i in 0...steps {
            let u: Double = ru + (1 - 2 * ru) * Double(i) / Double(steps)
            guard let a = at(cam, u, 0), let b = at(cam, u, 1) else { return nil }
            top.append(a)
            bottom.append(b)
        }
        guard let c00 = at(cam, 0, 0), let c10 = at(cam, 1, 0), let c11 = at(cam, 1, 1), let c01 = at(cam, 0, 1),
              let r0 = at(cam, 1, rv), let r1 = at(cam, 1, 1 - rv), let l0 = at(cam, 0, rv), let l1 = at(cam, 0, 1 - rv)
        else { return nil }
        var path = Path()
        path.move(to: top[0].cg)
        for q in top.dropFirst() { path.addLine(to: q.cg) }
        path.addQuadCurve(to: r0.cg, control: c10.cg)
        path.addLine(to: r1.cg)
        path.addQuadCurve(to: bottom[steps].cg, control: c11.cg)
        for q in bottom.reversed().dropFirst() { path.addLine(to: q.cg) }
        path.addQuadCurve(to: l1.cg, control: c01.cg)
        path.addLine(to: l0.cg)
        path.addQuadCurve(to: top[0].cg, control: c00.cg)
        path.closeSubpath()
        return path
    }

    /// A four cornered patch of the panel, for a block of its content.
    func patch(_ cam: TourCamera, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Path? {
        // On a bent panel the patch's long edges bend with it.
        let steps: Int = curve > 0.001 ? 8 : 1
        var points: [TourPoint] = []
        for i in 0...steps {
            let u: Double = a + (c - a) * Double(i) / Double(steps)
            guard let p = at(cam, u, b) else { return nil }
            points.append(p)
        }
        for i in 0...steps {
            let u: Double = c - (c - a) * Double(i) / Double(steps)
            guard let p = at(cam, u, d) else { return nil }
            points.append(p)
        }
        return TourDraw.poly(points, closed: true)
    }
}

/// What a screen shows: a sketch of an app, never a real one.
enum TourKind {
    case text, media, chat, list, blank
}

/// The canvas a picture is drawn on, and the eye it is usually seen from.
struct TourStage {
    let w: Double
    let h: Double

    /// Points at 1 m for a picture that fills the canvas.
    var focal: Double { min(w, h * 1.35) * 0.92 }

    func cam(yaw: Double = 0, shiftX: Double = 0, cyShare: Double = 0.5, zoom: Double = 1) -> TourCamera {
        TourCamera(yawDeg: yaw, focal: focal * zoom, cx: w / 2, cy: h * cyShare, shiftX: shiftX)
    }
}

/// The drawing primitives. A GraphicsContext draws without being changed, so it is passed by value; a clip or a blur
/// is put on a copy.
enum TourDraw {
    // ---- screens and windows ----

    /// A screen's glass: the focus halo just outside its edge (light, not shadow) and the smoked fill. Returns the
    /// outline for its content to be clipped to and its rim drawn on, or nil when it is out of sight.
    static func glass(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, focus: Double = 0, held: Double = 0, alpha: Double = 1) -> Path? {
        if alpha <= 0.01 { return nil }
        guard let outline = win.outline(cam) else { return nil }
        halo(g, outline, focus: focus, held: held, alpha: alpha)
        let b: CGRect = outline.boundingRect
        let shade = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [color(TourTone.glassTop, alpha), color(TourTone.glassBottom, alpha)]),
            startPoint: CGPoint(x: b.midX, y: b.minY),
            endPoint: CGPoint(x: b.midX, y: b.maxY)
        )
        g.fill(outline, with: shade)
        return outline
    }

    /// The halo: one soft stroke of the accent outside an edge. [held] turns it to the "you are holding this" colour.
    static func halo(_ g: GraphicsContext, _ outline: Path, focus: Double, held: Double, alpha: Double) {
        let glow: Double = max(focus, held)
        if glow <= 0.01 { return }
        var soft = g
        soft.addFilter(.blur(radius: 9))
        let tone = TourMath.mixC(TourTone.accent, TourTone.held, held)
        soft.stroke(outline, with: .color(color(tone, 0.42 * glow * alpha)), lineWidth: 5)
    }

    /// The hairline rim: brighter in focus, the held colour while carried.
    static func rim(_ g: GraphicsContext, _ outline: Path, focus: Double = 0, held: Double = 0, alpha: Double = 1) {
        let tone = TourMath.mixC(TourMath.mixC(TourTone.rim, TourTone.rimFocus, focus), TourTone.held, held)
        stroke(g, outline, tone, width: 1.5, alpha: alpha)
    }

    /// A window as the glasses show it: glass, a sketch of an app, the rim.
    static func window(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, _ kind: TourKind, focus: Double = 0, held: Double = 0, alpha: Double = 1) {
        guard let outline = glass(g, cam, win, focus: focus, held: held, alpha: alpha) else { return }
        content(g, cam, win, kind, alpha)
        rim(g, outline, focus: focus, held: held, alpha: alpha)
    }

    /// One of the Mac's floating screens: glass with the menu bar's strip along its top and an app's window on it.
    static func screen(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, _ kind: TourKind, focus: Double = 0, held: Double = 0, alpha: Double = 1) {
        guard let outline = glass(g, cam, win, focus: focus, held: held, alpha: alpha) else { return }
        var inside = g
        inside.clip(to: outline)
        menuStrip(inside, cam, win, alpha)
        if kind != .blank {
            let app = win.part(0.09, 0.19, 0.91, 0.9)
            miniWindow(inside, cam, app, kind, alpha: alpha)
        }
        rim(g, outline, focus: focus, held: held, alpha: alpha)
    }

    /// The menu bar along a screen's top: a lighter strip with a few marks, enough to say "this is a Mac's display".
    static func menuStrip(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, _ alpha: Double) {
        block(g, cam, win, 0, 0, 1, 0.085, TourTone.tint(0.06), alpha)
        winLine(g, cam, win, 0.04, 0.055, 0.043, TourTone.tint(0.5), alpha, width: 2.5)
        winLine(g, cam, win, 0.1, 0.19, 0.043, TourTone.tint(0.2), alpha, width: 2)
        winLine(g, cam, win, 0.23, 0.3, 0.043, TourTone.tint(0.2), alpha, width: 2)
        winLine(g, cam, win, 0.88, 0.96, 0.043, TourTone.tint(0.2), alpha, width: 2)
    }

    /// An app's window on a screen: its own glass, three dots, a sketch of what it shows. [win] is the part of the
    /// screen it covers.
    static func miniWindow(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, _ kind: TourKind, held: Double = 0, alpha: Double = 1) {
        guard let outline = win.outline(cam, radius: 0.022) else { return }
        halo(g, outline, focus: 0, held: held, alpha: alpha)
        fill(g, outline, TourTone.window, alpha)
        var dotU: Double = 0.05
        for _ in 0..<3 {
            if let p = win.at(cam, dotU, 0.085) { disc(g, p, 1.8, TourTone.tint(0.4), alpha) }
            dotU += 0.045
        }
        content(g, cam, win.part(0, 0.12, 1, 1), kind, alpha)
        let tone = TourMath.mixC(TourTone.rimFocus, TourTone.held, held)
        stroke(g, outline, tone, width: 1.2, alpha: alpha)
    }

    /// The same window flat on the Mac's own screen.
    static func miniWindowFlat(_ g: GraphicsContext, _ box: TourBox, held: Double = 0, alpha: Double = 1) {
        let radius: Double = min(box.w, box.h) * 0.08
        let outline = roundRect(box, radius)
        halo(g, outline, focus: 0, held: held, alpha: alpha)
        fill(g, outline, TourTone.window, alpha)
        for i in 0..<3 {
            disc(g, box.at(0.07 + 0.065 * Double(i), 0.12), max(box.w * 0.016, 1.2), TourTone.tint(0.4), alpha)
        }
        let ends: [Double] = [0.86, 0.7, 0.8]
        for (i, end) in ends.enumerated() {
            let v: Double = 0.38 + 0.2 * Double(i)
            line(g, box.at(0.1, v), box.at(end, v), TourTone.tint(0.16), width: 2.5, alpha: alpha)
        }
        let tone = TourMath.mixC(TourTone.rimFocus, TourTone.held, held)
        stroke(g, outline, tone, width: 1.2, alpha: alpha)
    }

    /// A line of a screen's content from ([a], [v]) to ([b], [v]).
    static func winLine(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, _ a: Double, _ b: Double, _ v: Double, _ c: LookColor, _ alpha: Double, width: Double = 3) {
        guard let p = win.at(cam, a, v), let q = win.at(cam, b, v) else { return }
        line(g, p, q, c, width: width, alpha: alpha)
    }

    static func block(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, _ a: Double, _ b: Double, _ c: Double, _ d: Double, _ tone: LookColor, _ alpha: Double) {
        guard let path = win.patch(cam, a, b, c, d) else { return }
        fill(g, path, tone, alpha)
    }

    static func content(_ g: GraphicsContext, _ cam: TourCamera, _ win: TourPanel, _ kind: TourKind, _ alpha: Double) {
        let soft = TourTone.tint(0.16)
        let softer = TourTone.tint(0.09)
        switch kind {
        case .blank:
            break
        case .text:
            winLine(g, cam, win, 0.1, 0.5, 0.16, TourTone.tint(0.34), alpha, width: 4)
            let ends: [Double] = [0.9, 0.84, 0.88, 0.6, 0.86, 0.72]
            var v: Double = 0.32
            for end in ends {
                winLine(g, cam, win, 0.1, end, v, soft, alpha)
                v += 0.105
            }
        case .media:
            block(g, cam, win, 0.07, 0.1, 0.93, 0.7, TourTone.media, alpha)
            // A play mark in the picture's middle.
            if let a = win.at(cam, 0.46, 0.31), let b = win.at(cam, 0.46, 0.49), let c = win.at(cam, 0.56, 0.4) {
                fill(g, poly([a, b, c], closed: true), TourTone.tint(0.7), alpha)
            }
            winLine(g, cam, win, 0.07, 0.55, 0.8, TourTone.tint(0.34), alpha, width: 4)
            winLine(g, cam, win, 0.07, 0.38, 0.9, softer, alpha)
        case .chat:
            let mine = TourTone.accentDeep.alpha(0.75)
            block(g, cam, win, 0.08, 0.12, 0.62, 0.26, soft, alpha)
            block(g, cam, win, 0.4, 0.33, 0.92, 0.47, mine, alpha)
            block(g, cam, win, 0.08, 0.54, 0.7, 0.68, soft, alpha)
            block(g, cam, win, 0.52, 0.75, 0.92, 0.89, mine, alpha)
        case .list:
            var v: Double = 0.16
            for i in 0..<5 {
                block(g, cam, win, 0.08, v - 0.045, 0.2, v + 0.045, softer, alpha)
                winLine(g, cam, win, 0.27, i % 2 == 0 ? 0.86 : 0.7, v, soft, alpha)
                v += 0.17
            }
        }
    }

    // ---- the pointer ----

    /// The Mac's pointer, its tip at [at]: a light arrow with a dark hairline and a little glow.
    static func pointer(_ g: GraphicsContext, _ at: TourPoint, alpha: Double = 1, scale: Double = 1) {
        if alpha <= 0.01 { return }
        disc(g, TourPoint(at.x + 4 * scale, at.y + 7 * scale), 13 * scale, TourTone.tint(0.1), alpha)
        let shape: [(Double, Double)] = [(0, 0), (0, 16), (4.2, 12.3), (7, 18.3), (9.7, 17.1), (6.9, 11.3), (12, 11.3)]
        let points: [TourPoint] = shape.map { TourPoint(at.x + $0.0 * scale, at.y + $0.1 * scale) }
        let arrow = poly(points, closed: true)
        fill(g, arrow, TourTone.white, alpha)
        stroke(g, arrow, TourTone.page, width: 1.1, alpha: alpha * 0.9)
    }

    /// A click answering: a ring going out, [k] 0 to 1.
    static func ripple(_ g: GraphicsContext, _ at: TourPoint, _ k: Double, _ tone: LookColor = TourTone.accent, alpha: Double = 1) {
        let e: Double = LookEase.enter(k)
        ring(g, at, 7 + 20 * e, tone.alpha(0.7 * (1 - e)), width: 2, alpha: alpha)
    }

    // ---- the things themselves ----

    /// A pair of glasses, front on, [width] wide about [centre]. [lit] 0 to 1 lights the lenses in the accent.
    /// Returns the box they take, arms included.
    @discardableResult
    static func glasses(_ g: GraphicsContext, _ centre: TourPoint, width: Double, lit: Double = 0, alpha: Double = 1, weight: Double = 2.5) -> TourBox {
        let lensW: Double = width * 0.4
        let lensH: Double = width * 0.24
        let gap: Double = width * 0.1
        let top: Double = centre.y - lensH / 2
        let leftX: Double = centre.x - gap / 2 - lensW
        let rightX: Double = centre.x + gap / 2
        let radius: Double = lensH * 0.34
        let frame = TourMath.mixC(TourTone.ink, TourTone.white, lit)
        let grow: Double = min(6, width * 0.05)
        for x in [leftX, rightX] {
            let lens = TourBox(x, top, lensW, lensH)
            if lit > 0.01 {
                let glow = TourBox(x - grow, top - grow, lensW + 2 * grow, lensH + 2 * grow)
                fill(g, roundRect(glow, radius + grow), TourTone.accent.alpha(0.22 * lit), alpha)
            }
            fill(g, roundRect(lens, radius), TourMath.mixC(TourTone.glassRaised, TourTone.lens, lit), alpha)
            stroke(g, roundRect(lens, radius), frame, width: weight, alpha: alpha)
        }
        let bridgeY: Double = top + lensH * 0.3
        line(g, TourPoint(centre.x - gap / 2, bridgeY), TourPoint(centre.x + gap / 2, bridgeY), frame, width: weight, alpha: alpha)
        let arm: Double = width * 0.09
        line(g, TourPoint(leftX, bridgeY), TourPoint(leftX - arm, bridgeY - arm * 0.45), frame, width: weight, alpha: alpha)
        line(g, TourPoint(rightX + lensW, bridgeY), TourPoint(rightX + lensW + arm, bridgeY - arm * 0.45), frame, width: weight, alpha: alpha)
        return TourBox(leftX - arm, top, 2 * lensW + gap + 2 * arm, lensH)
    }

    /// Where the right arm of glasses drawn in [box] ends (a cable goes in there).
    static func glassesArmEnd(_ box: TourBox) -> TourPoint { TourPoint(box.maxX, box.y + box.h * 0.13) }

    /// A Mac, lid open, seen from the front: [box] is its screen's lid; the base is drawn under it. Returns the
    /// screen inside the lid, for the picture to draw on.
    @discardableResult
    static func mac(_ g: GraphicsContext, _ box: TourBox, alpha: Double = 1) -> TourBox {
        let radius: Double = box.w * 0.045
        let lid = roundRect(box, radius)
        fill(g, lid, TourTone.glassRaised, alpha)
        let inner = macScreen(box)
        fill(g, roundRect(inner, max(radius - box.w * 0.03, 1)), TourTone.pad, alpha)
        stroke(g, lid, TourTone.rimFocus, width: 1.5, alpha: alpha)
        let base = macBase(box)
        let slab = roundRect(base, base.h / 2)
        fill(g, slab, TourTone.glassRaised, alpha)
        stroke(g, slab, TourTone.rimFocus, width: 1.2, alpha: alpha)
        // The dip a thumb opens the lid by.
        line(g, TourPoint(box.midX - box.w * 0.06, base.y + 1), TourPoint(box.midX + box.w * 0.06, base.y + 1), TourTone.rimFocus, width: 1.5, alpha: alpha)
        return inner
    }

    static func macScreen(_ box: TourBox) -> TourBox { box.inset(box.w * 0.03) }

    static func macBase(_ box: TourBox) -> TourBox {
        let bw: Double = box.w * 1.18
        let bh: Double = max(box.w * 0.035, 4)
        return TourBox(box.midX - bw / 2, box.maxY + 1.5, bw, bh)
    }

    /// The USB-C port on the Mac's right side.
    static func macPort(_ box: TourBox) -> TourPoint {
        let base = macBase(box)
        return TourPoint(base.maxX, base.midY)
    }

    /// The Mac's own desktop on its screen: the menu bar's strip and the Dock, faint.
    static func macDesktop(_ g: GraphicsContext, _ inner: TourBox, alpha: Double = 1) {
        let strip = inner.part(0, 0, 1, 0.085)
        fill(g, Path(strip.cg), TourTone.tint(0.06), alpha)
        line(g, inner.at(0.04, 0.043), inner.at(0.055, 0.043), TourTone.tint(0.5), width: 2.5, alpha: alpha)
        line(g, inner.at(0.1, 0.043), inner.at(0.19, 0.043), TourTone.tint(0.2), width: 2, alpha: alpha)
        line(g, inner.at(0.23, 0.043), inner.at(0.3, 0.043), TourTone.tint(0.2), width: 2, alpha: alpha)
        let dock = inner.part(0.32, 0.9, 0.68, 0.965)
        fill(g, roundRect(dock, dock.h / 2), TourTone.tint(0.08), alpha)
    }

    /// A key: [pressed] 0 to 1 pushes it down, [lit] lights it in the accent.
    static func keyCap(_ g: GraphicsContext, _ centre: TourPoint, w: Double, h: Double, _ label: String, pressed: Double = 0, lit: Double = 0, alpha: Double = 1) {
        if alpha <= 0.01 { return }
        let radius: Double = min(w, h) * 0.24
        let edge = TourBox(centre.x - w / 2, centre.y - h / 2 + 3, w, h)
        fill(g, roundRect(edge, radius), TourTone.keyEdge, alpha)
        stroke(g, roundRect(edge, radius), TourTone.rim, width: 1, alpha: alpha)
        let top = TourBox(centre.x - w / 2, centre.y - h / 2 + 2.5 * pressed, w, h)
        if lit > 0.01 {
            var soft = g
            soft.addFilter(.blur(radius: 8))
            soft.stroke(roundRect(top, radius), with: .color(color(TourTone.accent, 0.45 * lit * alpha)), lineWidth: 4)
        }
        fill(g, roundRect(top, radius), TourMath.mixC(TourTone.control, TourTone.accent, lit), alpha)
        stroke(g, roundRect(top, radius), TourMath.mixC(TourTone.rimFocus, TourTone.white, lit), width: 1.2, alpha: alpha)
        label_(g, label, TourPoint(top.midX, top.midY), size: h * 0.42, TourTone.white, alpha * 0.95)
    }

    /// A tick drawing itself inside a ring: [ring] and [tick] 0 to 1. The tick is two strokes.
    static func tickRing(_ g: GraphicsContext, _ centre: TourPoint, _ radius: Double, ring: Double, tick: Double, _ tone: LookColor = TourTone.accent, alpha: Double = 1, width: Double = 2.5) {
        if ring > 0.001 {
            var arc = Path()
            arc.addArc(center: centre.cg, radius: CGFloat(radius), startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(ring, 1)), clockwise: false)
            stroke(g, arc, tone, width: width, alpha: alpha)
        }
        if tick > 0.001 {
            let a = TourPoint(centre.x - radius * 0.42, centre.y + radius * 0.02)
            let b = TourPoint(centre.x - radius * 0.1, centre.y + radius * 0.34)
            let c = TourPoint(centre.x + radius * 0.46, centre.y - radius * 0.3)
            let first: Double = min(max(tick / 0.4, 0), 1)
            let second: Double = min(max((tick - 0.4) / 0.6, 0), 1)
            line(g, a, TourMath.mixP(a, b, first), tone, width: width, alpha: alpha)
            if second > 0 { line(g, b, TourMath.mixP(b, c, second), tone, width: width, alpha: alpha) }
        }
    }

    // ---- CoreGraphics from here down ----

    static func color(_ c: LookColor, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a * min(max(alpha, 0), 1))
    }

    static func roundRect(_ box: TourBox, _ radius: Double) -> Path {
        let r: Double = max(min(radius, min(box.w, box.h) / 2), 0)
        return Path(roundedRect: box.cg, cornerRadius: CGFloat(r))
    }

    static func poly(_ points: [TourPoint], closed: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first.cg)
        for p in points.dropFirst() { path.addLine(to: p.cg) }
        if closed { path.closeSubpath() }
        return path
    }

    static func fill(_ g: GraphicsContext, _ path: Path, _ c: LookColor, _ alpha: Double = 1) {
        if alpha <= 0.004 { return }
        g.fill(path, with: .color(color(c, alpha)))
    }

    /// A stroke with round ends and joins.
    static func stroke(_ g: GraphicsContext, _ path: Path, _ c: LookColor, width: Double, alpha: Double = 1) {
        if alpha <= 0.004 { return }
        let style = StrokeStyle(lineWidth: CGFloat(width), lineCap: .round, lineJoin: .round)
        g.stroke(path, with: .color(color(c, alpha)), style: style)
    }

    static func dashed(_ g: GraphicsContext, _ path: Path, _ c: LookColor, width: Double, dash: Double, gap: Double, alpha: Double = 1) {
        if alpha <= 0.004 { return }
        let style = StrokeStyle(lineWidth: CGFloat(width), lineCap: .round, lineJoin: .round, dash: [CGFloat(dash), CGFloat(gap)])
        g.stroke(path, with: .color(color(c, alpha)), style: style)
    }

    static func line(_ g: GraphicsContext, _ a: TourPoint, _ b: TourPoint, _ c: LookColor, width: Double, alpha: Double = 1) {
        stroke(g, poly([a, b], closed: false), c, width: width, alpha: alpha)
    }

    static func disc(_ g: GraphicsContext, _ at: TourPoint, _ radius: Double, _ c: LookColor, _ alpha: Double = 1) {
        let box = TourBox(at.x - radius, at.y - radius, radius * 2, radius * 2)
        fill(g, Path(ellipseIn: box.cg), c, alpha)
    }

    static func ring(_ g: GraphicsContext, _ at: TourPoint, _ radius: Double, _ c: LookColor, width: Double, alpha: Double = 1) {
        let box = TourBox(at.x - radius, at.y - radius, radius * 2, radius * 2)
        stroke(g, Path(ellipseIn: box.cg), c, width: width, alpha: alpha)
    }

    /// A few words in a picture (a key's letter, a menu's row), in the system font.
    static func label_(_ g: GraphicsContext, _ words: String, _ at: TourPoint, size: Double, _ c: LookColor, _ alpha: Double = 1, leading: Bool = false) {
        if alpha <= 0.01 { return }
        let text = Text(words).font(.system(size: CGFloat(size), weight: .medium)).foregroundColor(color(c, alpha))
        g.draw(text, at: at.cg, anchor: leading ? UnitPoint.leading : UnitPoint.center)
    }
}
