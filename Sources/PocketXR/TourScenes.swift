import PocketXRCore
import SwiftUI

// The tour's pictures, one per step (the Android app's TourScenes.kt, for a Mac). Each is drawn from the seconds since
// it came up, so it is the same picture every time and a still at any moment. Each has one thing the eye follows, what
// answers it, and slow life behind; nothing moves that the words do not say. The beats the words follow (which line is
// lit when) are the core's Tour.phase; change both together.
//
// This file: the arc of screens, setup, the screens as real displays, looking around. TourScenes2.swift has the rest.

/// What the Arrange picture shows: the Space's own values, or (until the first touch) its own demonstration.
struct TourArrangeInput {
    var sizeDeg: Double = 40
    var distance: Double = 1.4
    var curve: Double = 0
    /// The layout being left, the one arrived at, and how far between them, 0 to 1.
    var from: ArrangeLayout = .row
    var to: ArrangeLayout = .row
    var mix: Double = 1
    var screens: Int = 2
    /// Nobody has touched a control yet: the picture shows bigger, nearer and curved by itself.
    var ghost: Bool = true
}

/// What a picture needs beside the time.
struct TourSceneInput {
    /// 0 to 1: the glasses are really seen (the cable lights).
    var link: Double = 0
    /// Seconds since everything needed was set up, or nil while something is still to do (the last step's tick).
    var completeFor: Double? = nil
    var arrange = TourArrangeInput()
}

private typealias M = TourMath
private typealias D = TourDraw
private typealias T = TourTone

enum TourScenes {
    /// Draws [step]'s picture as it is [t] seconds after it came up.
    static func draw(_ step: TourStep, _ g: GraphicsContext, _ size: CGSize, t: Double, input: TourSceneInput) {
        let s = TourStage(w: Double(size.width), h: Double(size.height))
        if s.w < 8 || s.h < 8 { return }
        let time: Double = max(t, 0)
        switch step {
        case .welcome: welcome(g, s, t: time)
        case .setup: setup(g, s, t: time, link: input.link)
        case .screens: screens(g, s, t: time)
        case .look: look(g, s, t: time)
        case .arrange: arrange(g, s, t: time, input: input.arrange)
        case .depth: depth(g, s, t: time)
        case .menu: menu(g, s, t: time)
        case .done: done(g, s, t: time, completeFor: input.completeFor)
        }
    }

    // ---- 1. Welcome: the Mac's screens all around, the view drifting as a head would ----

    /// The arc: degrees to the right, metres up, what each screen shows. The middle one first.
    static let arc: [(theta: Double, y: Double, kind: TourKind)] = [
        (0, 0, TourKind.media),
        (-31, 0.03, TourKind.chat),
        (31, -0.02, TourKind.text),
        (-62, -0.02, TourKind.list),
        (62, 0.03, TourKind.text),
    ]

    static func welcome(_ g: GraphicsContext, _ s: TourStage, t: Double) {
        let cam = s.cam(yaw: 6 * sin(t * 0.5), cyShare: 0.4, zoom: 0.8)
        let breathe: Double = 0.82 + 0.18 * sin(t * 1.3)
        macUnderArc(g, s, t: t, glow: breathe, yShare: 0.8, lightTo: 0.53)
        for (i, item) in arc.enumerated() {
            let delay: Double = 0.14 * Double((i + 1) / 2)
            let a: Double = M.span(t, delay, delay + 0.55)
            let win = TourPanel(theta: item.theta, y: item.y - (1 - a) * 0.05, w: 0.92, h: 0.58)
            let focus: Double = i == 0 ? breathe : 0
            let fade: Double = i == 0 ? 1 : 0.82
            D.screen(g, cam, win, item.kind, focus: focus, alpha: a * fade)
        }
    }

    /// The small Mac the screens belong to, at the bottom centre, with its light going up to them.
    static func macUnderArc(_ g: GraphicsContext, _ s: TourStage, t: Double, glow: Double, yShare: Double, lightTo: Double) {
        let a: Double = M.span(t, 0.3, 0.85)
        let mw: Double = min(s.w * 0.26, 150)
        let mh: Double = mw * 0.64
        let box = TourBox(s.w / 2 - mw / 2, s.h * yShare - mh / 2 + (1 - a) * 10, mw, mh)
        let topY: Double = s.h * lightTo
        var cone = Path()
        cone.move(to: CGPoint(x: box.midX - mw * 0.44, y: box.y))
        cone.addLine(to: CGPoint(x: box.midX + mw * 0.44, y: box.y))
        cone.addLine(to: CGPoint(x: box.midX + mw * 1.15, y: topY))
        cone.addLine(to: CGPoint(x: box.midX - mw * 1.15, y: topY))
        cone.closeSubpath()
        var soft = g
        soft.addFilter(.blur(radius: 16))
        let shade = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [D.color(T.accent, 0.2 * glow * a), D.color(T.accent, 0)]),
            startPoint: CGPoint(x: box.midX, y: box.y),
            endPoint: CGPoint(x: box.midX, y: topY)
        )
        soft.fill(cone, with: shade)
        let inner = D.mac(g, box, alpha: a)
        D.macDesktop(g, inner, alpha: a)
        let picture = inner.part(0.2, 0.24, 0.8, 0.8)
        D.fill(g, D.roundRect(picture, 3), T.media, a)
    }

    // ---- 2. Get set up: a Mac, glasses, and the cable between them ----

    static func setup(_ g: GraphicsContext, _ s: TourStage, t: Double, link: Double) {
        let unit: Double = min(s.w, s.h * 1.5)
        let enter: Double = M.span(t, 0, 0.5)
        let glassesEnter: Double = M.span(t, 0.08, 0.58)
        let cableAlpha: Double = M.span(t, 0.2, 0.7)

        let mw: Double = unit * 0.44
        let mh: Double = mw * 0.64
        let box = TourBox(s.w / 2 - unit * 0.05 - mw / 2, s.h * 0.6 - mh / 2 + (1 - enter) * 10, mw, mh)
        let inner = D.mac(g, box, alpha: enter)
        D.macDesktop(g, inner, alpha: enter)

        let centre = TourPoint(s.w / 2 - unit * 0.02, s.h * 0.25 + (1 - glassesEnter) * 10)
        let glassesBox = D.glasses(g, centre, width: unit * 0.4, lit: link, alpha: glassesEnter)

        // The cable: from the Mac's port, out to the right and up to the end of the glasses' arm.
        let port = D.macPort(box)
        let arm = D.glassesArmEnd(glassesBox)
        // Unplugged, the plug waits a little way from the port and nudges toward it: this is the thing to do.
        let swing: Double = 0.5 - 0.5 * cos(2 * Double.pi * t / 1.8)
        let nudge: Double = (1 - link) * (16 - 6 * swing)
        let plug = TourPoint(port.x + 4 + nudge, port.y)
        var cable = Path()
        cable.move(to: plug.cg)
        cable.addCurve(
            to: CGPoint(x: arm.x + unit * 0.05, y: arm.y + s.h * 0.03),
            control1: CGPoint(x: plug.x + unit * 0.22, y: plug.y),
            control2: CGPoint(x: arm.x + unit * 0.2, y: arm.y + s.h * 0.16)
        )
        cable.addQuadCurve(to: arm.cg, control: CGPoint(x: arm.x + unit * 0.03, y: arm.y + s.h * 0.008))
        D.stroke(g, cable, M.mixC(T.ink3, T.ink2, link), width: 2, alpha: cableAlpha)
        let plugBox = TourBox(plug.x - 4, plug.y - 3.5, 11, 7)
        D.fill(g, D.roundRect(plugBox, 2.5), M.mixC(T.ink2, T.white, link), cableAlpha)

        if link < 0.5 {
            // Two small chevrons pointing at the port.
            let k: Double = (t / 1.8).truncatingRemainder(dividingBy: 1)
            let a: Double = (1 - link * 2) * cableAlpha * (0.25 + 0.55 * sin(Double.pi * k))
            let x: Double = port.x + 34 - 4 * k
            let c: Double = 4
            let offsets: [Double] = [0, 7]
            for dx in offsets {
                let tip = TourPoint(x + dx, port.y - 15)
                let chevron = D.poly([TourPoint(tip.x + c, tip.y - c), tip, TourPoint(tip.x + c, tip.y + c)], closed: false)
                D.stroke(g, chevron, T.accent, width: 2, alpha: a)
            }
        }
        if link > 0.01 {
            // Light running along the cable to the glasses, again and again while they are connected.
            let k: Double = (t / 2.2).truncatingRemainder(dividingBy: 1)
            runLight(g, cable, k: k, alpha: link * cableAlpha)
        }
    }

    /// A segment of light at [k] 0 to 1 of its way along [cable].
    static func runLight(_ g: GraphicsContext, _ cable: Path, k: Double, alpha: Double) {
        let head: Double = M.ease(.inOut, k) * 1.2
        let from: Double = max(head - 0.2, 0)
        let to: Double = min(head, 1)
        if to <= from { return }
        let lit = cable.trimmedPath(from: CGFloat(from), to: CGFloat(to))
        D.stroke(g, lit, T.accent.alpha(0.3), width: 8, alpha: alpha)
        D.stroke(g, lit, T.accent, width: 3, alpha: alpha)
    }

    // ---- 3. Your screens are real displays: the pointer leaves the Mac's screen, a window is carried across ----

    static func screens(_ g: GraphicsContext, _ s: TourStage, t: Double) {
        let loop: Double = Tour.screensLoop
        let lt: Double = Tour.loopTime(t, loop)
        let alpha: Double = M.loopAlpha(lt, loop) * M.span(t, 0, 0.4)
        let cam = s.cam(cyShare: 0.3, zoom: 0.8)
        let first = TourPanel(theta: 9, y: 0, w: 1.04, h: 0.65)
        let second = TourPanel(theta: 51, y: 0, w: 1.04, h: 0.65)

        // The Mac, lower left; the floating screens are to its right, as macOS has them.
        let mw: Double = min(s.w * 0.4, s.h * 0.4)
        let mh: Double = mw * 0.64
        let box = TourBox(s.w * 0.07, s.h * 0.66, mw, mh)
        let inner = D.macScreen(box)

        // Places are on one desktop: x 0 to 1 is the Mac's screen, 1 to 2 the first floating screen.
        let edgeY: Double = 0.72
        let k1: Double = M.span(lt, 0.5, 1.5, .inOut)
        let k3: Double = M.span(lt, 1.8, 2.4)
        let k4: Double = M.span(lt, 2.7, 3.1, .inOut)
        let k6: Double = M.span(lt, 3.3, 3.85, .inOut)
        let carry: Double = M.span(lt, 4.2, 5.9, .inOut)
        let held: Double = M.span(lt, 3.9, 4.02) * (1 - M.span(lt, 6.1, 6.26, .exit))
        let ww: Double = 0.36
        let wh: Double = 0.42
        let wx: Double = M.mix(0.26, 1.3, carry)
        let wy: Double = M.mix(0.32, 0.26, carry)
        let grabX: Double = 0.18
        let grabY: Double = 0.05

        // The pointer: off the right edge and onto the floating screen, back for the window, then across with it.
        let px: Double
        let py: Double
        if lt < 1.65 {
            px = M.mix(0.3, 1.0, k1)
            py = M.mix(0.5, edgeY, k1)
        } else if lt < 3.2 {
            let out: Double = k3 - k4
            px = 1.0001 + 0.4 * out
            py = M.mix(edgeY, 0.6, out)
        } else if lt < 4.2 {
            px = M.mix(1.0, 0.26 + grabX, k6)
            py = M.mix(edgeY, 0.32 + grabY, k6)
        } else {
            px = wx + grabX
            py = wy + grabY
        }
        let visit: Double = M.span(lt, 1.65, 1.8) * (1 - M.span(lt, 3.1, 3.25))
        let focus: Double = max(visit, M.span(lt, 4.8, 4.95))

        // The join between the two: a dotted line light runs along each time something crosses.
        let from = TourPoint(inner.maxX + 9, inner.at(1, edgeY).y)
        let join: TourPoint = first.at(cam, 0, edgeY) ?? TourPoint(s.w * 0.4, s.h * 0.36)
        let to = TourPoint(join.x - 9, join.y)
        var link = Path()
        link.move(to: from.cg)
        link.addQuadCurve(to: to.cg, control: CGPoint(x: from.x + 26, y: to.y + (from.y - to.y) * 0.3))
        D.dashed(g, link, T.rimFocus, width: 1.5, dash: 1, gap: 6, alpha: alpha * 0.8)
        let crossings: [(at: Double, back: Bool)] = [(1.5, false), (3.05, true), (4.68, false)]
        var edge: Double = 0
        for crossing in crossings {
            guard let k = M.burst(lt, crossing.at, 0.35) else { continue }
            edge = max(edge, sin(Double.pi * k))
            let head: Double = M.ease(.inOut, k) * 1.25
            let a0: Double = max(head - 0.25, 0)
            let a1: Double = min(head, 1)
            if a1 > a0 {
                let lo: Double = crossing.back ? 1 - a1 : a0
                let hi: Double = crossing.back ? 1 - a0 : a1
                D.stroke(g, link.trimmedPath(from: CGFloat(lo), to: CGFloat(hi)), T.accent, width: 2.5, alpha: alpha)
            }
        }

        // The floating screens: a second one waits further right; the first lights while the pointer is on it.
        D.screen(g, cam, second, .blank, alpha: alpha * 0.7)
        if let outline = D.glass(g, cam, first, focus: focus, alpha: alpha) {
            var inside = g
            inside.clip(to: outline)
            D.menuStrip(inside, cam, first, alpha)
            if wx + ww > 1 {
                let part = first.part(wx - 1, wy, wx - 1 + ww, wy + wh)
                D.miniWindow(inside, cam, part, .text, held: held, alpha: alpha)
            }
            D.rim(g, outline, focus: focus, alpha: alpha)
        }
        if edge > 0.01, let a = first.at(cam, 0, 0.08), let b = first.at(cam, 0, 0.92) {
            D.line(g, a, b, T.accent, width: 2.5, alpha: alpha * edge)
        }

        // The Mac's own screen, with the window while it is still there.
        D.mac(g, box, alpha: alpha)
        D.macDesktop(g, inner, alpha: alpha)
        if wx < 1 {
            var inside = g
            inside.clip(to: D.roundRect(inner, 3))
            let flat = TourBox(inner.x + inner.w * wx, inner.y + inner.h * wy, inner.w * ww, inner.h * wh)
            D.miniWindowFlat(inside, flat, held: held, alpha: alpha)
        }
        if edge > 0.01 {
            D.line(g, inner.at(1, 0.08), inner.at(1, 0.92), T.accent, width: 2.5, alpha: alpha * edge)
        }

        // The pointer goes out at one edge and is at the other at once, as on any second display.
        let hop1: Double = M.span(lt, 1.5, 1.6) * (1 - M.span(lt, 1.72, 1.82))
        let hop2: Double = M.span(lt, 3.05, 3.15) * (1 - M.span(lt, 3.27, 3.37))
        let pointerAlpha: Double = alpha * (1 - hop1) * (1 - hop2)
        let tip: TourPoint?
        if px > 1 {
            tip = first.at(cam, px - 1, py)
        } else {
            tip = inner.at(px, py)
        }
        if let tip {
            if let k = M.burst(lt, 3.9, 0.45) { D.ripple(g, tip, k, alpha: alpha) }
            if let k = M.burst(lt, 6.1, 0.45) { D.ripple(g, tip, k, alpha: alpha) }
            D.pointer(g, tip, alpha: pointerAlpha)
        }
    }

    // ---- 4. Look around, and Recentre ----

    static func look(_ g: GraphicsContext, _ s: TourStage, t: Double) {
        let loop: Double = Tour.lookLoop
        let lt: Double = Tour.loopTime(t, loop)
        let alpha: Double = M.loopAlpha(lt, loop) * M.span(t, 0, 0.4)
        let yaw: Double = 46 * M.span(lt, 0.9, 2.9, .inOut)
        let centre: Double = 46 * M.span(lt, 4.25, 5.0)
        let cam = s.cam(yaw: yaw, cyShare: 0.45, zoom: 0.82)
        let row: [(theta: Double, y: Double, kind: TourKind)] = [
            (-39, 0.02, TourKind.chat),
            (0, 0, TourKind.media),
            (39, -0.02, TourKind.text),
        ]
        for (i, item) in row.enumerated() {
            let win = TourPanel(theta: item.theta + centre, y: item.y, w: 0.92, h: 0.58)
            let focus: Double = i == 1 ? 1 : 0
            let fade: Double = i == 1 ? 1 : 0.85
            D.screen(g, cam, win, item.kind, focus: focus, alpha: alpha * fade)
        }

        // Over it, which way the head points (the white mark) and where the screens are centred (the blue one).
        let rulerW: Double = min(s.w * 0.56, 240)
        let rulerY: Double = s.h * 0.07 + 4
        let rulerX: Double = s.w / 2
        let perDeg: Double = rulerW / 120
        D.line(g, TourPoint(rulerX - rulerW / 2, rulerY), TourPoint(rulerX + rulerW / 2, rulerY), T.rim, width: 1.5, alpha: alpha)
        var degrees: Double = -60
        while degrees <= 60 {
            let x: Double = rulerX + degrees * perDeg
            D.line(g, TourPoint(x, rulerY - 3), TourPoint(x, rulerY + 3), T.rimFocus, width: 1, alpha: alpha)
            degrees += 15
        }
        D.disc(g, TourPoint(rulerX + centre * perDeg, rulerY), 4.5, T.accent, alpha)
        let headX: Double = rulerX + yaw * perDeg
        let head = D.poly([TourPoint(headX, rulerY + 5), TourPoint(headX - 5, rulerY + 13), TourPoint(headX + 5, rulerY + 13)], closed: true)
        D.fill(g, head, T.ink, alpha)

        // Control, Option and R: they light as the press comes, go down together, and the screens glide back.
        let press: Double = M.pulse(lt, 4.05, 0.5)
        let ready: Double = M.span(lt, 3.5, 4.0) * (1 - M.span(lt, 5.0, 5.5)) * 0.5
        let lit: Double = max(press, ready)
        let keyW: Double = min(s.w * 0.11, 50)
        let keyH: Double = keyW * 0.9
        let gap: Double = keyW * 0.18
        let keyY: Double = s.h * 0.88
        let labels: [String] = ["⌃", "⌥", "R"]
        for (i, label) in labels.enumerated() {
            let x: Double = s.w / 2 + (Double(i) - 1) * (keyW + gap)
            D.keyCap(g, TourPoint(x, keyY), w: keyW, h: keyH, label, pressed: press, lit: lit, alpha: alpha)
        }
    }
}
