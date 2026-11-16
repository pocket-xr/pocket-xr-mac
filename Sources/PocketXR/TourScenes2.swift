import PocketXRCore
import SwiftUI

// The tour's pictures, continued: arranging the Space, 3D and Steady mode, the menu, and the last step.

private typealias M = TourMath
private typealias D = TourDraw
private typealias T = TourTone

/// Where one screen goes in a layout, for the Arrange picture: degrees to the right, how far up in its own heights,
/// its size against the others, and how much further away than the Space's distance.
struct TourSpot {
    var yaw: Double
    var lift: Double
    var scale: Double
    var far: Double
}

extension TourScenes {
    // ---- 5. Make the Space yours: the screens seen from behind your seat, moving with the controls ----

    /// A sketch of each layout for 1 to 3 screens. The Space itself is laid out by the app's own layout code; this
    /// only has to read as the same arrangement.
    static func spots(_ layout: ArrangeLayout, count: Int, sizeDeg: Double) -> [TourSpot] {
        let n: Int = min(max(count, 1), 3)
        let step: Double = sizeDeg + 2
        let middle: Double = Double(n - 1) / 2
        var out: [TourSpot] = []
        switch layout {
        case .row:
            for i in 0..<n {
                out.append(TourSpot(yaw: (Double(i) - middle) * step, lift: 0, scale: 1, far: 1))
            }
        case .theater:
            for i in 0..<n {
                out.append(TourSpot(yaw: (Double(i) - middle) * step, lift: 0, scale: 1, far: 1.7))
            }
        case .mainSide:
            let side: Double = 0.6
            let yaw: Double = sizeDeg / 2 + 2 + sizeDeg * side / 2
            out.append(TourSpot(yaw: 0, lift: 0, scale: 1, far: 1))
            if n == 2 {
                out.append(TourSpot(yaw: yaw, lift: 0, scale: side, far: 1))
            } else if n == 3 {
                out.append(TourSpot(yaw: yaw, lift: 0.54, scale: side, far: 1))
                out.append(TourSpot(yaw: yaw, lift: -0.54, scale: side, far: 1))
            }
        case .stacked:
            for i in 0..<n {
                out.append(TourSpot(yaw: 0, lift: (middle - Double(i)) * 1.08, scale: 1, far: 1))
            }
        }
        return out
    }

    /// The picture's own demonstration at [t]: bigger, then nearer, then curved.
    static func arrangeGhost(_ t: Double) -> (sizeDeg: Double, distance: Double, curve: Double) {
        let demo = Tour.arrangeDemo(t)
        let size: Double = M.mix(40, 56, M.ease(.inOut, demo.bigger))
        let distance: Double = M.mix(1.4, 1.0, M.ease(.inOut, demo.nearer))
        let curve: Double = M.mix(0, 1, M.ease(.inOut, demo.curved))
        return (size, distance, curve)
    }

    static func arrange(_ g: GraphicsContext, _ s: TourStage, t: Double, input: TourArrangeInput) {
        let loop: Double = Tour.arrangeLoop
        let lt: Double = Tour.loopTime(t, loop)
        var alpha: Double = M.span(t, 0, 0.4)
        var sizeDeg: Double = input.sizeDeg
        var distance: Double = input.distance
        var curve: Double = input.curve
        var from: ArrangeLayout = input.from
        var to: ArrangeLayout = input.to
        var blend: Double = input.mix
        if input.ghost {
            alpha *= M.loopAlpha(lt, loop)
            let ghost = arrangeGhost(t)
            sizeDeg = ghost.sizeDeg
            distance = ghost.distance
            curve = ghost.curve
            from = .row
            to = .row
            blend = 1
        }
        let n: Int = min(max(input.screens, 1), 3)
        // Far settings are drawn closer than they are, so the picture stays a picture.
        let d: Double = distance <= 2 ? distance : 2 + (distance - 2) * 0.35

        // The eye is behind and above the viewer, looking down a little.
        var cam = s.cam(cyShare: 0.47, zoom: n == 3 ? 1.45 : 1.75)
        cam.back = 2.6
        cam.up = 1.25
        cam.pitchDeg = -21

        let a = spots(from, count: n, sizeDeg: sizeDeg)
        let b = spots(to, count: n, sizeDeg: sizeDeg)
        var panels: [TourPanel] = []
        for i in 0..<n {
            let yaw: Double = M.mix(a[i].yaw, b[i].yaw, blend)
            let lift: Double = M.mix(a[i].lift, b[i].lift, blend)
            let scale: Double = M.mix(a[i].scale, b[i].scale, blend)
            let far: Double = M.mix(a[i].far, b[i].far, blend)
            let r: Double = d * far
            let angle: Double = min(sizeDeg * scale, 150)
            let w: Double = 2 * r * tan(M.radians(angle / 2))
            let h: Double = w / 1.6
            panels.append(TourPanel(theta: yaw, y: lift * h, w: w, h: h, r: r, curve: curve))
        }
        guard let main = panels.first else { return }

        // Slow life behind: the circle at the screens' distance, at eye height, and the angle the first screen fills.
        var ringPath = Path()
        var drawing = false
        var degrees: Double = -110
        while degrees <= 110 {
            let angle: Double = M.radians(degrees)
            if let p = cam.project(main.r * sin(angle), 0, main.r * cos(angle)) {
                if drawing {
                    ringPath.addLine(to: p.cg)
                } else {
                    ringPath.move(to: p.cg)
                    drawing = true
                }
            } else {
                drawing = false
            }
            degrees += 5
        }
        D.stroke(g, ringPath, T.rim, width: 1.2, alpha: alpha)
        let head = cam.project(0, 0, 0)
        if let head, let left = main.at(cam, 0, 0.5), let right = main.at(cam, 1, 0.5) {
            D.line(g, head, left, T.rimFocus, width: 1, alpha: alpha * 0.6)
            D.line(g, head, right, T.rimFocus, width: 1, alpha: alpha * 0.6)
        }

        // The screens, far ones first.
        let kinds: [TourKind] = [.media, .text, .chat]
        let order: [Int] = panels.indices.sorted { panels[$0].depth(cam) > panels[$1].depth(cam) }
        for i in order {
            let focus: Double = i == 0 ? 1 : 0
            let fade: Double = i == 0 ? 1 : 0.9
            D.screen(g, cam, panels[i], kinds[i % kinds.count], focus: focus, alpha: alpha * fade)
        }

        // You, in the middle of it.
        if let head {
            D.glasses(g, head, width: 52, lit: 1, alpha: alpha, weight: 2)
        }
    }

    // ---- 6. 3D and Steady mode ----

    static func depth(_ g: GraphicsContext, _ s: TourStage, t: Double) {
        let loop: Double = Tour.depthLoop
        let rowAt: Double = Tour.depthRowAt
        let lt: Double = Tour.loopTime(t, loop)
        let alpha: Double = M.loopAlpha(lt, loop) * M.span(t, 0, 0.4)
        let row: Double = M.span(lt, rowAt, rowAt + 0.9, .inOut)
        // 3D: the two eyes' pictures come together, then a small sway shows near screens moving more than far ones.
        let apart: Double = (1 - M.span(lt, 0.3, 1.5, .inOut)) * 0.11
        let swing: Double = sin(max(lt - 1.5, 0) * 1.5)
        let sway: Double = 0.13 * swing * M.span(lt, 1.5, 2.1) * (1 - row)
        let near = TourPanel(theta: M.mix(-24, -27, row), y: M.mix(-0.05, 0, row), w: M.mix(0.4, 0.7, row), h: M.mix(0.27, 0.46, row), r: M.mix(1.0, 1.6, row))
        let mid = TourPanel(theta: M.mix(1, 0, row), y: 0, w: M.mix(0.74, 0.7, row), h: M.mix(0.48, 0.46, row), r: 1.6)
        let far = TourPanel(theta: M.mix(25, 27, row), y: M.mix(0.12, 0, row), w: M.mix(1.02, 0.7, row), h: M.mix(0.66, 0.46, row), r: M.mix(2.5, 1.6, row))
        let locked: Double = M.span(lt, rowAt + 0.9, rowAt + 1.3)
        let zoom: Double = M.mix(0.8, 0.62, row)
        let midFocus: Double = 1 - row

        func pass(_ shift: Double, _ a: Double) {
            let cam = s.cam(shiftX: shift, cyShare: 0.46, zoom: zoom)
            D.screen(g, cam, far, .text, alpha: a)
            D.screen(g, cam, mid, .media, focus: midFocus, alpha: a)
            D.screen(g, cam, near, .chat, alpha: a)
        }
        if apart > 0.004 {
            pass(sway - apart, alpha * 0.55)
            pass(sway + apart, alpha * 0.55)
        } else {
            pass(sway, alpha)
        }
        if locked > 0.01 {
            // Steady mode: one brighter rim round the whole row, the wide screen holding still.
            let cam = s.cam(cyShare: 0.46, zoom: 0.62)
            if let a = near.at(cam, 0, 0), let b = far.at(cam, 1, 1) {
                let pad: Double = 9
                let around = TourBox(a.x - pad, a.y - pad, b.x - a.x + 2 * pad, b.y - a.y + 2 * pad)
                D.stroke(g, D.roundRect(around, 16), T.rimFocus, width: 1.5, alpha: alpha * locked)
            }
        }
    }

    // ---- 7. Always in your menu bar ----

    /// The menu's rows as the picture shows them (the last is the one the words name).
    static let menuRows: [String] = ["Recentre", "Layout", "Settings…", "Tour of Pocket XR", "Send logs to Mike", "Quit and put the glasses back"]

    static func menu(_ g: GraphicsContext, _ s: TourStage, t: Double) {
        let loop: Double = Tour.menuLoop
        let lt: Double = Tour.loopTime(t, loop)
        let alpha: Double = M.loopAlpha(lt, loop) * M.span(t, 0, 0.4)

        // The second half: the cable comes out, the floating screen goes, the windows come home.
        let unplug: Double = M.span(lt, 5.7, 6.3, .inOut)
        let link: Double = 1 - M.span(lt, 5.9, 6.4)
        let gone: Double = M.span(lt, 6.4, 7.1, .exit)
        let home: Double = M.span(lt, 6.3, 7.5, .inOut)

        // The floating screen, straight ahead and above.
        let cam = s.cam(cyShare: 0.21, zoom: 0.8)
        let panel = TourPanel(theta: 0, y: 0, w: 1.0, h: 0.6)
        let screenAlpha: Double = alpha * (1 - gone)
        if let outline = D.glass(g, cam, panel, focus: link, alpha: screenAlpha) {
            var inside = g
            inside.clip(to: outline)
            D.menuStrip(inside, cam, panel, screenAlpha)
            D.rim(g, outline, focus: link, alpha: screenAlpha)
        }

        // The Mac below it, the glasses beside, and the cable between them.
        let mw: Double = min(s.w * 0.62, s.h * 0.56)
        let mh: Double = mw * 0.62
        let box = TourBox(s.w * 0.06, s.h * 0.5, mw, mh)
        let inner = D.macScreen(box)
        let glassesBox = D.glasses(g, TourPoint(s.w * 0.8, s.h * 0.4), width: s.w * 0.2, lit: link, alpha: alpha, weight: 2)
        let port = D.macPort(box)
        let arm = D.glassesArmEnd(glassesBox)
        let plug = TourPoint(port.x + 4 + 14 * unplug, port.y)
        var cable = Path()
        cable.move(to: plug.cg)
        cable.addCurve(
            to: CGPoint(x: arm.x + 12, y: arm.y + 18),
            control1: CGPoint(x: plug.x + 70, y: plug.y),
            control2: CGPoint(x: arm.x + 46, y: arm.y + 130)
        )
        cable.addQuadCurve(to: arm.cg, control: CGPoint(x: arm.x + 8, y: arm.y + 4))
        D.stroke(g, cable, M.mixC(T.ink3, T.ink2, link), width: 2, alpha: alpha)
        let plugBox = TourBox(plug.x - 4, plug.y - 3.5, 11, 7)
        D.fill(g, D.roundRect(plugBox, 2.5), M.mixC(T.ink2, T.white, link), alpha)
        if link > 0.01 {
            let k: Double = (lt / 2.2).truncatingRemainder(dividingBy: 1)
            runLight(g, cable, k: k, alpha: link * alpha)
        }

        D.mac(g, box, alpha: alpha)
        D.macDesktop(g, inner, alpha: alpha)

        // The glasses icon in the Mac's menu bar, and the menu that drops from it.
        let rows: [String] = menuRows
        let open: Double = M.span(lt, 0.9, 1.1) * (1 - M.span(lt, 5.0, 5.16, .exit))
        let icon = inner.at(0.8, 0.043)
        D.glasses(g, icon, width: max(inner.h * 0.09, 12), lit: open, alpha: alpha, weight: 1.2)
        let rowH: Double = min(inner.h * 0.118, 23)
        let menuW: Double = min(inner.w * 0.6, 190)
        let menuH: Double = rowH * Double(rows.count) + 10
        let menuX: Double = min(icon.x - 18, inner.maxX - menuW - 5)
        let menuTop: Double = inner.y + inner.h * 0.085 + 3
        let menuBox = TourBox(menuX, menuTop - (1 - open) * 6, menuW, menuH)
        // The highlight walks down three rows, then goes to the last one.
        let walk: Double = M.span(lt, 1.9, 2.15, .inOut) + M.span(lt, 2.5, 2.75, .inOut)
        let pos: Double = walk + 3 * M.span(lt, 3.4, 3.8, .inOut)
        let highlight: Double = M.span(lt, 1.3, 1.45) * open
        if open > 0.01 {
            let sheet = D.roundRect(menuBox, 8)
            D.halo(g, sheet, focus: 0.6 * open, held: 0, alpha: alpha)
            D.fill(g, sheet, T.window, alpha * open)
            D.stroke(g, sheet, T.rimFocus, width: 1.2, alpha: alpha * open)
            let lit = TourBox(menuBox.x + 4, menuBox.y + 5 + rowH * pos, menuW - 8, rowH)
            D.fill(g, D.roundRect(lit, 5), T.accent, alpha * highlight)
            let ruleY: Double = menuBox.y + 5 + rowH * Double(rows.count - 1)
            D.line(g, TourPoint(menuBox.x + 10, ruleY), TourPoint(menuBox.maxX - 10, ruleY), T.rim, width: 1, alpha: alpha * open)
            for (i, row) in rows.enumerated() {
                // Rows arrive 40 ms apart.
                let arrive: Double = M.span(lt, 0.95 + 0.04 * Double(i), 1.15 + 0.04 * Double(i)) * open
                let on: Bool = highlight > 0.5 && abs(pos - Double(i)) < 0.5
                let tone: LookColor = on ? T.white : T.tint(0.82)
                let at = TourPoint(menuBox.x + 14, menuBox.y + 5 + rowH * (Double(i) + 0.5))
                D.label_(g, row, at, size: min(rowH * 0.47, 10.5), tone, alpha * arrive, leading: true)
            }
        }

        // The windows: on the floating screen while the glasses are plugged in, back on the Mac's screen after.
        if let topLeft = panel.at(cam, 0, 0), let bottomRight = panel.at(cam, 1, 1) {
            let floating = TourBox(topLeft.x, topLeft.y, bottomRight.x - topLeft.x, bottomRight.y - topLeft.y)
            let one = M.mixB(floating.part(0.07, 0.2, 0.5, 0.8), inner.part(0.07, 0.22, 0.47, 0.74), home)
            let two = M.mixB(floating.part(0.55, 0.3, 0.93, 0.85), inner.part(0.52, 0.36, 0.9, 0.86), home)
            D.miniWindowFlat(g, one, alpha: alpha)
            D.miniWindowFlat(g, two, alpha: alpha)
        }

        // The pointer: to the icon, a click, down the menu with the highlight; it leaves when the menu closes.
        let toIcon: Double = M.span(lt, 0.3, 0.85, .inOut)
        let toRow: Double = M.span(lt, 1.15, 1.45, .inOut)
        let start = inner.at(0.42, 0.62)
        let onIcon = TourPoint(icon.x, icon.y + 3)
        let onRow = TourPoint(menuX + menuW * 0.6, menuTop + 5 + rowH * (pos + 0.5))
        let tip = M.mixP(M.mixP(start, onIcon, toIcon), onRow, toRow)
        let pointerAlpha: Double = alpha * (1 - M.span(lt, 5.2, 5.5, .exit))
        if let k = M.burst(lt, 0.88, 0.45) { D.ripple(g, tip, k, alpha: alpha) }
        D.pointer(g, tip, alpha: pointerAlpha)
    }

    // ---- 8. You're set ----

    static func done(_ g: GraphicsContext, _ s: TourStage, t: Double, completeFor: Double?) {
        let cam = s.cam(yaw: 5 * sin(t * 0.45), cyShare: 0.4, zoom: 0.72)
        macUnderArc(g, s, t: t, glow: 1, yShare: 0.8, lightTo: 0.52)
        for (i, item) in arc.enumerated() {
            let delay: Double = 0.1 * Double((i + 1) / 2)
            let a: Double = M.span(t, delay, delay + 0.55)
            let win = TourPanel(theta: item.theta * 0.92, y: item.y - (1 - a) * 0.05, w: 0.86, h: 0.54)
            let focus: Double = i == 0 ? 1 : 0
            let fade: Double = i == 0 ? 1 : 0.8
            D.screen(g, cam, win, item.kind, focus: focus, alpha: a * fade)
        }
        if let since = completeFor {
            // The tick is drawn only when everything needed really is set up.
            let centre = TourPoint(s.w / 2, s.h * 0.4)
            let radius: Double = min(s.h * 0.1, 34)
            D.disc(g, centre, radius + 9, T.page.alpha(0.82), M.span(since, 0.5, 0.8))
            D.tickRing(g, centre, radius, ring: M.span(since, 0.6, 1.1, .inOut), tick: M.span(since, 1.0, 1.4), width: 3)
        }
    }
}
