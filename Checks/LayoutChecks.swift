import Foundation
import simd

/// Do two screens' angular rectangles (yaw by pitch, degrees) share any area?
private func layoutRectsOverlap(_ a: PanelPlacement, _ b: PanelPlacement) -> Bool {
    let eps = 1e-9
    let yawApart = a.yawDeg - a.widthDeg / 2 >= b.yawDeg + b.widthDeg / 2 - eps
        || b.yawDeg - b.widthDeg / 2 >= a.yawDeg + a.widthDeg / 2 - eps
    let pitchApart = a.pitchDeg - a.heightDeg / 2 >= b.pitchDeg + b.heightDeg / 2 - eps
        || b.pitchDeg - b.heightDeg / 2 >= a.pitchDeg + a.heightDeg / 2 - eps
    return !(yawApart || pitchApart)
}

/// The angle of a mesh vertex to the right of straight ahead, degrees.
private func layoutAzimuthDeg(_ v: PanelVertex) -> Double {
    atan2(Double(v.position.x), Double(-v.position.z)) * 180 / Double.pi
}

func layoutChecks() {
    let wide = 16.0 / 9.0

    // The displays are laid out as the screens look, so the pointer crosses the way the eye expects.
    let hd: [(width: Int, height: Int)] = [(width: 1920, height: 1080), (width: 1920, height: 1080)]
    let gridRow = DisplayGrid.origins(panels: SpaceLayout.arrange(layout: .row, aspects: [wide, wide], widthDeg: 40, distance: 1.4, curve: 0), sizes: hd)
    check(gridRow[0].x == 0 && gridRow[0].y == 0 && gridRow[1].x == 1920 && gridRow[1].y == 0, "display grid: a row is left to right")
    let gridStack = DisplayGrid.origins(panels: SpaceLayout.arrange(layout: .stacked, aspects: [wide, wide], widthDeg: 40, distance: 1.4, curve: 0), sizes: hd)
    check(gridStack[0].x == 0 && gridStack[1].x == 0 && abs(gridStack[0].y - gridStack[1].y) == 1080, "display grid: stacked is above and below")
    let stackPanels = SpaceLayout.arrange(layout: .stacked, aspects: [wide, wide], widthDeg: 40, distance: 1.4, curve: 0)
    let upper = stackPanels[0].pitchDeg > stackPanels[1].pitchDeg ? 0 : 1
    check(gridStack[upper].y == 0 && gridStack[1 - upper].y == 1080, "display grid: the upper screen is the upper display")
    let hd3 = hd + [(width: 1920, height: 1080)]
    let gridSide = DisplayGrid.origins(panels: SpaceLayout.arrange(layout: .mainSide, aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 0), sizes: hd3)
    check(gridSide[0].x == 0 && gridSide[0].y == 0 && gridSide[1].x == 1920 && gridSide[2].x == 1920, "display grid: main + side has the sides in a column to the right")
    check(abs(gridSide[1].y - gridSide[2].y) == 1080 && min(gridSide[1].y, gridSide[2].y) == -540, "display grid: the side column is centred on the main screen")
    let gridOdd = DisplayGrid.origins(panels: [], sizes: hd)
    check(gridOdd[0].x == 0 && gridOdd[1].x == 1920 && gridOdd[1].y == 0, "display grid: a plain row when the counts differ")

    // The row is as it was: symmetric, 2 degrees between screens, its middle straight ahead.
    let row3 = SpaceLayout.row(aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4)
    check(row3.count == 3, "row: three screens")
    check(near(row3[0].yawDeg, 42) && near(row3[1].yawDeg, 0) && near(row3[2].yawDeg, -42), "row: 42, 0, -42 degrees")
    let rowGap = (row3[0].yawDeg - row3[0].widthDeg / 2) - (row3[1].yawDeg + row3[1].widthDeg / 2)
    check(near(rowGap, 2), "row: 2 degrees between screens")
    check(near(SpaceLayout.middleYawDeg(row3), 0), "row: middle yaw 0")
    check(row3.allSatisfy { $0.curve == 0 && $0.pitchDeg == 0 && $0.distance == 1.4 }, "row: flat, level, at its distance")
    let row2 = SpaceLayout.row(aspects: [wide, wide], widthDeg: 40, distance: 1.4)
    check(near(row2[0].yawDeg, 21) && near(row2[1].yawDeg, -21), "row: two screens at 21 and -21 degrees")
    check(SpaceLayout.row(aspects: [], widthDeg: 40, distance: 1.4).isEmpty, "row: no screens, no placements")
    check(PanelPlacement(yawDeg: 0, widthDeg: 40, aspect: wide, distance: 1.4).curve == 0, "a placement is flat by default")
    let arrangedRow = SpaceLayout.arrange(layout: .row, aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 0)
    check(arrangedRow == row3, "arrange: the row layout is the row")

    // Every layout, 1 to 3 screens, narrow to wide: the right count, no overlap, centred, inside 35 degrees.
    for layout in ArrangeLayout.allCases {
        for count in 1...3 {
            for width in [15.0, 40.0, 70.0, 100.0] {
                let aspects = [Double](repeating: wide, count: count)
                let panels = SpaceLayout.arrange(layout: layout, aspects: aspects, widthDeg: width, distance: 1.4, curve: 0)
                let what = "\(layout.rawValue) x\(count) at \(width) degrees"
                check(panels.count == count, "\(what): one placement per screen")
                var overlap = false
                for i in 0..<panels.count {
                    for j in (i + 1)..<max(panels.count, i + 1) {
                        if layoutRectsOverlap(panels[i], panels[j]) { overlap = true }
                    }
                }
                check(!overlap, "\(what): no two screens overlap")
                let mid = SpaceLayout.middle(panels)
                check(near(mid.yawDeg, 0, 1e-6) && near(mid.pitchDeg, 0, 1e-6), "\(what): its middle is straight ahead")
                let limit = SpaceLayout.maxPitchDeg + 1e-6
                let inside = panels.allSatisfy { abs($0.pitchDeg) + $0.heightDeg / 2 <= limit }
                check(inside, "\(what): inside 35 degrees up and down")
            }
        }
    }

    // The layouts' own proportions.
    let ms2 = SpaceLayout.arrange(layout: .mainSide, aspects: [wide, wide], widthDeg: 40, distance: 1.4, curve: 0)
    check(near(ms2[0].widthDeg, 40) && near(ms2[1].widthDeg, 24), "main + side: 40 and 24 degrees wide")
    check(near(ms2[0].yawDeg, 13) && near(ms2[1].yawDeg, -21), "main + side: the main screen left, the side right")
    let ms3 = SpaceLayout.arrange(layout: .mainSide, aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 0)
    check(near(ms3[1].widthDeg, 20) && near(ms3[2].widthDeg, 20), "main + two stacked: sides 20 degrees wide")
    check(near(ms3[1].yawDeg, ms3[2].yawDeg) && ms3[1].pitchDeg > 0 && near(ms3[1].pitchDeg, -ms3[2].pitchDeg),
          "main + two stacked: one column, the second screen above the third")
    let sideGap = (ms3[1].pitchDeg - ms3[1].heightDeg / 2) - (ms3[2].pitchDeg + ms3[2].heightDeg / 2)
    check(near(sideGap, 2), "main + two stacked: 2 degrees between the side screens")
    check(ms3[0].yawDeg - ms3[0].widthDeg / 2 - (ms3[1].yawDeg + ms3[1].widthDeg / 2) >= 2 - 1e-9,
          "main + two stacked: at least 2 degrees between main and column")

    let st2 = SpaceLayout.arrange(layout: .stacked, aspects: [wide, wide], widthDeg: 40, distance: 1.4, curve: 0)
    check(near(st2[0].widthDeg, 40) && near(st2[0].yawDeg, 0) && near(st2[1].yawDeg, 0), "stacked: full width, one column")
    check(st2[0].pitchDeg > 0 && near(st2[0].pitchDeg, -st2[1].pitchDeg), "stacked: the first screen on top")
    let stGap = (st2[0].pitchDeg - st2[0].heightDeg / 2) - (st2[1].pitchDeg + st2[1].heightDeg / 2)
    check(near(stGap, 2), "stacked: 2 degrees between screens")
    let st3 = SpaceLayout.arrange(layout: .stacked, aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 0)
    check(st3[0].widthDeg < 40 && near(st3[0].widthDeg, st3[2].widthDeg), "stacked: three shrink together to fit")
    check(near(st3[0].pitchDeg + st3[0].heightDeg / 2, 35, 1e-4), "stacked: three reach just 35 degrees up")

    let th1 = SpaceLayout.arrange(layout: .theater, aspects: [wide], widthDeg: 40, distance: 1.4, curve: 0)
    let theaterDeg = 2 * atan(2.1 / 5.0) * 180 / Double.pi
    check(near(th1[0].distance, 5) && near(th1[0].widthDeg, theaterDeg), "theater: 4.2 m wide at 5 m")
    check(near(th1[0].sizeMetres.x, 4.2, 1e-9), "theater: 4.2 m across")
    let th3 = SpaceLayout.arrange(layout: .theater, aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 0)
    check(near(th3[0].yawDeg, 0) && th3[1].yawDeg > 0 && near(th3[1].yawDeg, -th3[2].yawDeg), "theater: flanked left and right")
    check(near(th3[1].distance, 1.4) && near(th3[1].widthDeg, 24), "theater: flanks at the user's distance, 24 degrees")

    // Fallbacks, curve, names.
    let one = SpaceLayout.arrange(layout: .mainSide, aspects: [wide], widthDeg: 40, distance: 1.4, curve: 1)
    check(one.count == 1 && near(one[0].yawDeg, 0) && one[0].curve == 1, "main + side with one screen is the row, curved")
    let four = SpaceLayout.arrange(layout: .stacked, aspects: [wide, wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 9)
    check(four.count == 4 && four.allSatisfy { $0.pitchDeg == 0 && $0.curve == 2.5 }, "four screens fall back to the row; curve held to 2.5")
    check(SpaceLayout.arrange(layout: .theater, aspects: [], widthDeg: 40, distance: 1.4, curve: 0).isEmpty, "no screens, no placements")
    check(SpaceLayout.choices(count: 1) == [.row, .theater], "choices for one screen")
    check(SpaceLayout.choices(count: 2) == [.row, .mainSide, .stacked, .theater], "choices for two screens")
    check(SpaceLayout.choices(count: 3) == [.row, .mainSide, .stacked, .theater], "choices for three screens")
    check(SpaceLayout.title(.row, count: 1) == "Center" && SpaceLayout.title(.row, count: 2) == "Side by side"
        && SpaceLayout.title(.row, count: 3) == "Three across", "row titles")
    check(SpaceLayout.title(.mainSide, count: 2) == "Main + side" && SpaceLayout.title(.mainSide, count: 3) == "Main + two stacked",
          "main + side titles")
    check(SpaceLayout.title(.stacked, count: 2) == "Stacked" && SpaceLayout.title(.theater, count: 1) == "Theater", "other titles")
    let offCentre = [PanelPlacement(yawDeg: 30, pitchDeg: 10, widthDeg: 20, aspect: wide, distance: 1.4)]
    let offMid = SpaceLayout.middle(offCentre)
    check(near(offMid.yawDeg, 30) && near(offMid.pitchDeg, 10), "middle: one screen's own centre")
    let none = SpaceLayout.middle([])
    check(none.yawDeg == 0 && none.pitchDeg == 0, "middle: (0, 0) with no screens")

    // A flat mesh is the unit quad times the model matrix.
    let tilted = PanelPlacement(yawDeg: 25, pitchDeg: -10, widthDeg: 40, aspect: wide, distance: 1.4)
    let flat = tilted.mesh()
    check(flat.count == 4, "flat mesh: 4 vertices")
    let corners: [SIMD2<Float>] = [SIMD2<Float>(-0.5, -0.5), SIMD2<Float>(0.5, -0.5), SIMD2<Float>(-0.5, 0.5), SIMD2<Float>(0.5, 0.5)]
    let uvs: [SIMD2<Float>] = [SIMD2<Float>(0, 1), SIMD2<Float>(1, 1), SIMD2<Float>(0, 0), SIMD2<Float>(1, 0)]
    let model = tilted.modelMatrix
    if flat.count == 4 {
        for i in 0..<4 {
            let q: SIMD4<Float> = model * SIMD4<Float>(corners[i].x, corners[i].y, 0, 1)
            let dx = Double(abs(q.x - flat[i].position.x))
            let dy = Double(abs(q.y - flat[i].position.y))
            let dz = Double(abs(q.z - flat[i].position.z))
            check(dx < 1e-5 && dy < 1e-5 && dz < 1e-5, "flat mesh: corner \(i) is the model matrix's")
            check(flat[i].uv == uvs[i], "flat mesh: corner \(i) uv")
            // The curved surface's own point agrees with the flat quad.
            let fx = Double(corners[i].x)
            let fy = Double(corners[i].y)
            let pt = PanelCurve.point(tilted, x: fx, y: fy)
            check(near(pt.x, Double(q.x), 1e-5) && near(pt.y, Double(q.y), 1e-5) && near(pt.z, Double(q.z), 1e-5),
                  "flat point \(i) agrees with the model matrix")
        }
    }

    // Curve 1: every column as far from the head, the same angular width as flat, uv 0...1.
    let curved = PanelPlacement(yawDeg: 0, widthDeg: 40, aspect: wide, distance: 1.4, curve: 1)
    let mesh = curved.mesh()
    check(mesh.count == 2 * 65, "curved mesh: 2 * (64 + 1) vertices")
    check(curved.mesh(columns: 8).count == 18, "curved mesh: 8 columns, 18 vertices")
    var allAtDistance = true
    var uvInside = true
    for v in mesh {
        let r = (Double(v.position.x) * Double(v.position.x) + Double(v.position.z) * Double(v.position.z)).squareRoot()
        if !near(r, 1.4, 1e-4) { allAtDistance = false }
        if v.uv.x < 0 || v.uv.x > 1 || v.uv.y < 0 || v.uv.y > 1 { uvInside = false }
    }
    check(allAtDistance, "curve 1: every vertex 1.4 m from the head in the horizontal plane")
    check(uvInside, "curved mesh: uv inside 0...1")
    if let first = mesh.first, let last = mesh.last, mesh.count >= 4 {
        check(near(layoutAzimuthDeg(first), -20, 1e-3) && near(layoutAzimuthDeg(last), 20, 1e-3), "curve 1: spans 40 degrees, as flat")
        check(first.uv == SIMD2<Float>(0, 0) && mesh[1].uv == SIMD2<Float>(0, 1), "curved mesh: starts top left, then bottom left")
        check(last.uv == SIMD2<Float>(1, 1) && mesh[mesh.count - 2].uv == SIMD2<Float>(1, 0), "curved mesh: ends top right, bottom right")
        let halfHeight = curved.sizeMetres.y / 2
        check(near(Double(first.position.y), halfHeight, 1e-5) && near(Double(mesh[1].position.y), -halfHeight, 1e-5),
              "curved mesh: the flat screen's height")
    }
    let flatMesh = PanelPlacement(yawDeg: 0, widthDeg: 40, aspect: wide, distance: 1.4).mesh()
    if flatMesh.count == 4 {
        check(near(layoutAzimuthDeg(flatMesh[0]), -20, 1e-3) && near(layoutAzimuthDeg(flatMesh[1]), 20, 1e-3), "flat: spans 40 degrees")
    }

    // The strongest curve: the same angular width, the edges nearer than the middle.
    let strong = PanelPlacement(yawDeg: 0, widthDeg: 40, aspect: wide, distance: 1.4, curve: 2.5)
    let strongMesh = strong.mesh()
    if let first = strongMesh.first, let last = strongMesh.last {
        check(near(layoutAzimuthDeg(first), -20, 1e-3) && near(layoutAzimuthDeg(last), 20, 1e-3), "curve 2.5: still spans 40 degrees")
        let edge = (Double(first.position.x) * Double(first.position.x) + Double(first.position.z) * Double(first.position.z)).squareRoot()
        check(edge < 1.4 - 0.1, "curve 2.5: the edges come clearly forward")
    }
    let middleColumn = strongMesh.count > 64 ? strongMesh[64] : nil
    check(middleColumn != nil && near(Double(middleColumn!.position.z), -1.4, 1e-5) && near(Double(middleColumn!.position.x), 0, 1e-5),
          "curve 2.5: the middle stays at its distance")
    check(near(PanelCurve.radius(strong), 1.4 / 2.5), "curve 2.5: radius is distance / curve")
    // A wide screen is held so its half arc stays at 85 degrees.
    let wideCurved = PanelPlacement(yawDeg: 0, widthDeg: 100, aspect: wide, distance: 1.4, curve: 2.5)
    check(near(PanelCurve.halfArc(wideCurved) * 180 / Double.pi, 85, 1e-6), "a wide screen's half arc is held to 85 degrees")
    check(near(PanelCurve.effective(curve: 0.6, widthDeg: 100), 0.6) && near(PanelCurve.effective(curve: 9, widthDeg: 40), 2.5),
          "effective curve: kept under 1, held to 2.5")
    check(!PanelCurve.isCurved(PanelPlacement(yawDeg: 0, widthDeg: 40, aspect: wide, distance: 1.4, curve: 0.004)), "a tiny curve is flat")

    // Which screen the head points at.
    let ahead = LookTarget.hit(head: Quat.identity, panels: row3)
    check(ahead != nil && ahead!.index == 1 && near(ahead!.u, 0.5) && near(ahead!.v, 0.5), "looking ahead: the centre screen's middle")
    let left = LookTarget.hit(head: Quat.aboutY(42 * Double.pi / 180), panels: row3)
    check(left != nil && left!.index == 0 && near(left!.u, 0.5) && near(left!.v, 0.5), "one step left: the left screen's middle")
    let right = LookTarget.hit(head: Quat.aboutY(-42 * Double.pi / 180), panels: row3)
    check(right != nil && right!.index == 2, "one step right: the right screen")
    check(LookTarget.hit(head: Quat.aboutY(Double.pi), panels: row3) == nil, "looking behind: no screen")
    check(LookTarget.hit(head: Quat.aboutY(21 * Double.pi / 180), panels: row3) == nil, "looking at the gap: no screen")
    check(LookTarget.hit(head: Quat.aboutX(60 * Double.pi / 180), panels: row3) == nil, "looking far up: no screen")
    check(LookTarget.hit(head: Quat.identity, panels: []) == nil, "no screens: nothing")
    // Where on the screen: a little left is u under a half, a little up is v under a half.
    let flatLeft = LookTarget.hit(head: Quat.aboutY(10 * Double.pi / 180), panels: row3)
    let expectU = 0.5 - tan(10 * Double.pi / 180) / (2 * tan(20 * Double.pi / 180))
    check(flatLeft != nil && flatLeft!.index == 1 && near(flatLeft!.u, expectU, 1e-9), "flat: 10 degrees left on the centre screen")
    let flatUp = LookTarget.hit(head: Quat.aboutX(5 * Double.pi / 180), panels: row3)
    let expectV = 0.5 - tan(5 * Double.pi / 180) * wide / (2 * tan(20 * Double.pi / 180))
    check(flatUp != nil && flatUp!.index == 1 && near(flatUp!.v, expectV, 1e-9) && near(flatUp!.u, 0.5), "flat: 5 degrees up on the centre screen")
    // Curved at 1, across the screen goes by angle.
    let curvedRow = SpaceLayout.arrange(layout: .row, aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 1)
    let curvedLeft = LookTarget.hit(head: Quat.aboutY(10 * Double.pi / 180), panels: curvedRow)
    check(curvedLeft != nil && curvedLeft!.index == 1 && near(curvedLeft!.u, 0.25, 1e-9) && near(curvedLeft!.v, 0.5), "curved: 10 of 40 degrees left is u 0.25")
    let curvedEdge = LookTarget.hit(head: Quat.aboutY(19.9 * Double.pi / 180), panels: curvedRow)
    check(curvedEdge != nil && curvedEdge!.index == 1, "curved: just inside the edge still hits")
    check(LookTarget.hit(head: Quat.aboutY(21 * Double.pi / 180), panels: curvedRow) == nil, "curved: the gap is still a gap")
    let strongRow = SpaceLayout.arrange(layout: .row, aspects: [wide, wide, wide], widthDeg: 40, distance: 1.4, curve: 2.5)
    let strongLeft = LookTarget.hit(head: Quat.aboutY(42 * Double.pi / 180), panels: strongRow)
    check(strongLeft != nil && strongLeft!.index == 0 && near(strongLeft!.u, 0.5, 1e-9), "curve 2.5: one step left is the left screen")
    check(LookTarget.hit(head: Quat.aboutY(19.9 * Double.pi / 180), panels: strongRow)?.index == 1, "curve 2.5: just inside the edge still hits")
    check(LookTarget.hit(head: Quat.aboutY(20.1 * Double.pi / 180), panels: strongRow) == nil, "curve 2.5: just outside the edge misses")
    // The stacked layout: looking up finds the top screen.
    let upAt = LookTarget.hit(head: Quat.aboutX(st2[0].pitchDeg * Double.pi / 180), panels: st2)
    check(upAt != nil && upAt!.index == 0 && near(upAt!.u, 0.5) && near(upAt!.v, 0.5), "stacked: looking up at the top screen's middle")

    // Each model's vertical field.
    func vertical(_ diagonal: Double) -> Double {
        2 * atan(tan(diagonal / 2 * Double.pi / 180) * 9 / (337.0).squareRoot()) * 180 / Double.pi
    }
    let aura = Glasses(name: "XREAL Aura", family: .aura, vendor: 0x3318, product: 0x043A)
    let oneGlasses = Glasses(name: "XREAL One", family: .one, vendor: 0x3318, product: 0x0438)
    let onePro = Glasses(name: "XREAL One Pro", family: .one, vendor: 0x3318, product: 0x0436)
    let oneProPlus = Glasses(name: "XREAL One Pro+", family: .one, vendor: 0x3318, product: 0x0444)
    let oneS = Glasses(name: "XREAL 1S", family: .one, vendor: 0x3318, product: 0x043D)
    let air = Glasses(name: "XREAL Air 2", family: .air, vendor: 0x3318, product: 0x0428)
    let beast = Glasses(name: "VITURE glasses", family: .viture, vendor: 0x35CA, product: 0x1211)
    let other = Glasses(name: "Some glasses", family: .other, vendor: 1, product: 2)
    check(GlassesOptics.fovYDeg(glasses: nil) == 38, "no glasses: 38 degrees")
    check(GlassesOptics.fovYDeg(glasses: aura) == 38, "Aura: 38 degrees")
    check(near(GlassesOptics.fovYDeg(glasses: oneGlasses), vertical(50), 1e-9), "One: 50 degrees diagonal")
    check(near(GlassesOptics.fovYDeg(glasses: oneGlasses), 25.75, 0.01), "One: about 25.75 degrees tall")
    check(near(GlassesOptics.fovYDeg(glasses: onePro), vertical(57), 1e-9), "One Pro: 57 degrees diagonal")
    check(near(GlassesOptics.fovYDeg(glasses: oneProPlus), vertical(57), 1e-9), "One Pro+: 57 degrees diagonal")
    check(near(GlassesOptics.fovYDeg(glasses: oneS), vertical(50), 1e-9), "1S: the One's 50 degrees")
    check(near(GlassesOptics.fovYDeg(glasses: air), vertical(46), 1e-9), "Air family: 46 degrees diagonal")
    check(near(GlassesOptics.fovYDeg(glasses: beast), vertical(50), 1e-9), "VITURE: 50 degrees diagonal")
    check(near(GlassesOptics.fovYDeg(glasses: other), vertical(50), 1e-9), "unknown glasses: 50 degrees diagonal")
    check(GlassesOptics.isSideBySide(width: 3840, height: 1080), "3840 x 1080 is side by side")
    check(!GlassesOptics.isSideBySide(width: 1920, height: 1080), "1920 x 1080 is not")
    check(!GlassesOptics.isSideBySide(width: 3440, height: 1440), "a 21:9 ultrawide is not")
    check(!GlassesOptics.isSideBySide(width: 3840, height: 0), "no height is not")
}
