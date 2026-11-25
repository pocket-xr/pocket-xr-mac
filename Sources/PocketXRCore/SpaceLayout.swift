import Foundation
import simd

/// Where one screen sits in the Space: a panel facing the head, at [distance] metres, turned [yawDeg] (left
/// positive) and [pitchDeg] (up positive), [widthDeg] wide. Its height follows the screen's aspect. [curve] bends it
/// round a vertical cylinder as a curved monitor (0 flat, 1 every column as far from the head, up to 2.5; PanelCurve).
public struct PanelPlacement: Equatable, Sendable {
    public var yawDeg: Double
    public var pitchDeg: Double
    public var widthDeg: Double
    public var aspect: Double // width / height
    public var distance: Double
    /// 0 flat ... 2.5 (PanelCurve.maxCurve). Its angular width stays [widthDeg] at any curve.
    public var curve: Double

    public init(yawDeg: Double, pitchDeg: Double = 0, widthDeg: Double, aspect: Double, distance: Double, curve: Double = 0) {
        self.yawDeg = yawDeg
        self.pitchDeg = pitchDeg
        self.widthDeg = widthDeg
        self.aspect = aspect
        self.distance = distance
        self.curve = curve
    }

    /// Width and height in metres at its distance (the flat screen's; a curved one keeps the height).
    public var sizeMetres: SIMD2<Double> {
        let w = 2 * distance * tan(widthDeg * .pi / 360)
        return SIMD2(w, w / aspect)
    }

    /// Its height as seen from the head, degrees (up its middle).
    public var heightDeg: Double {
        SpaceLayout.heightDeg(widthDeg: widthDeg, aspect: aspect)
    }

    /// The turn that puts the screen in its place: yaw about the up axis, then pitch about its own right axis.
    public var turn: Quat {
        Quat.aboutY(yawDeg * .pi / 180) * Quat.aboutX(pitchDeg * .pi / 180)
    }

    /// Model matrix: a unit quad (-0.5...0.5) scaled to the panel, pushed out to its distance, turned into place.
    /// This is the flat screen; a curved one is drawn from `mesh(columns:)`.
    public var modelMatrix: simd_float4x4 {
        let s = sizeMetres
        let scale = simd_float4x4(diagonal: SIMD4(Float(s.x), Float(s.y), 1, 1))
        var push = matrix_identity_float4x4
        push.columns.3 = SIMD4(0, 0, Float(-distance), 1)
        let turn = SpaceMath.rotation(Quat.aboutY(yawDeg * .pi / 180) * Quat.aboutX(pitchDeg * .pi / 180))
        return turn * push * scale
    }
}

/// The Space's layout and settings, as Pocket XR's PanelLayout has them (numbers from the Deck's space.py), and the
/// premade arrangements of Pocket XR's ArrangeLayouts for 1 to 6 screens (ScreenLimit.most).
public enum SpaceLayout {
    public static let defaultDistance = 1.4
    public static let defaultWidthDeg = 40.0
    public static let gapDeg = 2.0
    public static let minDistance = 0.5
    public static let maxDistance = 6.0
    public static let minWidthDeg = 15.0
    public static let maxWidthDeg = 90.0

    /// No arrangement reaches further up or down than this, degrees, so every screen stays in a comfortable range.
    public static let maxPitchDeg = 35.0
    /// Main + side: the one side screen's width as a share of the main screen's (Pocket XR: 1.0 m beside 1.8 m).
    public static let sideShare = 0.6
    /// Main + two stacked: each side screen's width as a share of the main screen's (Pocket XR: 0.9 m beside 1.8 m),
    /// so the column of two 16:9 screens is about as tall as the main screen.
    public static let sideShareTwo = 0.5
    /// Theater: Pocket XR's big screen is 4.2 m wide, 5 m away, for the default width of 40 degrees. It grows and
    /// shrinks with the width setting (times widthDeg / 40).
    public static let theaterWidthMetres = 4.2
    public static let theaterDistance = 5.0
    /// Theater: the other screens' width as a share of the width setting, at the user's distance.
    public static let theaterFlankShare = 0.6

    /// No arrangement reaches further round than this either side of straight ahead, degrees, so the two ends of a
    /// long row never meet behind the head (only more than 3 screens can get there: 3 at 100 degrees span 304).
    public static let maxYawDeg = 179.0

    /// [count] screens side by side on an arc around the head, the middle one straight ahead. Each angular width is
    /// [widthDeg]; [aspects] gives each screen's width / height. A row that would go further round than 179 degrees
    /// either side (4 or more wide screens) is narrowed to fit.
    public static func row(aspects: [Double], widthDeg: Double, distance: Double, gapDeg: Double = gapDeg) -> [PanelPlacement] {
        let n = aspects.count
        guard n > 0 else { return [] }
        let widest = (2 * maxYawDeg - gapDeg * Double(n - 1)) / Double(n)
        let w = min(widthDeg, widest)
        let step = w + gapDeg
        let first = step * Double(n - 1) / 2 // the leftmost, left positive
        return aspects.enumerated().map { i, aspect in
            PanelPlacement(yawDeg: first - step * Double(i), widthDeg: w, aspect: aspect, distance: distance)
        }
    }

    /// The middle of the row, for a recentre: 0 with the middle screen ahead.
    public static func middleYawDeg(_ panels: [PanelPlacement]) -> Double {
        guard let a = panels.first?.yawDeg, let b = panels.last?.yawDeg else { return 0 }
        return (a + b) / 2
    }

    // MARK: - The premade arrangements

    /// The layouts offered for [count] screens (1...6), in menu order. With one screen "Main + side" and "Stacked"
    /// would be the same as "Center", so they are left out.
    public static func choices(count: Int) -> [ArrangeLayout] {
        if count <= 0 { return [] }
        if count == 1 { return [.row, .theater] }
        return [.row, .mainSide, .stacked, .theater]
    }

    /// The layout's name for that count, as Pocket XR names them.
    public static func title(_ layout: ArrangeLayout, count: Int) -> String {
        switch layout {
        case .row:
            if count <= 1 { return "Center" }
            if count == 2 { return "Side by side" }
            return "\(numberWord(count).capitalized) across"
        case .mainSide:
            if count <= 1 { return "Center" } // one screen: the same as the row
            if count == 2 { return "Main + side" }
            return "Main + \(numberWord(count - 1)) stacked"
        case .stacked:
            return count > 3 ? "Two rows" : "Stacked"
        case .theater:
            return "Theater"
        }
    }

    /// A count as a word, for the layouts' names ("three", "four" ...); a number past six.
    private static func numberWord(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six"]
        return n >= 0 && n < words.count ? words[n] : "\(n)"
    }

    /// Where each screen goes. [aspects] are width / height per screen; [widthDeg] the main screen's angular width,
    /// [distance] metres, [curve] 0...2.5 applied to every screen. Anything else than 1 to 6 screens
    /// (ScreenLimit.most), and the two "main" layouts with one screen, fall back to the row.
    public static func arrange(layout: ArrangeLayout, aspects: [Double], widthDeg: Double, distance: Double, curve: Double) -> [PanelPlacement] {
        let n = aspects.count
        var out: [PanelPlacement]
        if n < 1 || n > ScreenLimit.most {
            out = row(aspects: aspects, widthDeg: widthDeg, distance: distance)
        } else {
            switch layout {
            case .row:
                out = row(aspects: aspects, widthDeg: widthDeg, distance: distance)
            case .mainSide:
                out = n == 1
                    ? row(aspects: aspects, widthDeg: widthDeg, distance: distance)
                    : mainSide(aspects: aspects, widthDeg: widthDeg, distance: distance)
            case .stacked:
                if n == 1 {
                    out = row(aspects: aspects, widthDeg: widthDeg, distance: distance)
                } else if n > 3 {
                    out = twoRows(aspects: aspects, widthDeg: widthDeg, distance: distance)
                } else {
                    out = stacked(aspects: aspects, widthDeg: widthDeg, distance: distance)
                }
            case .theater:
                out = theater(aspects: aspects, widthDeg: widthDeg, distance: distance)
            }
        }
        let c = min(max(curve, 0), PanelCurve.maxCurve)
        for i in out.indices {
            out[i].curve = c
        }
        return out
    }

    /// The yaw (left positive) and pitch of the middle of all the screens, for a recentre: the middle of the box
    /// round every screen's angular rectangle (Pocket XR's RecentreContent, with pitch added). (0, 0) with none.
    public static func middle(_ panels: [PanelPlacement]) -> (yawDeg: Double, pitchDeg: Double) {
        guard let p0 = panels.first else { return (yawDeg: 0, pitchDeg: 0) }
        var yawLo = p0.yawDeg - p0.widthDeg / 2
        var yawHi = p0.yawDeg + p0.widthDeg / 2
        var pitchLo = p0.pitchDeg - p0.heightDeg / 2
        var pitchHi = p0.pitchDeg + p0.heightDeg / 2
        for p in panels.dropFirst() {
            let h = p.heightDeg
            yawLo = min(yawLo, p.yawDeg - p.widthDeg / 2)
            yawHi = max(yawHi, p.yawDeg + p.widthDeg / 2)
            pitchLo = min(pitchLo, p.pitchDeg - h / 2)
            pitchHi = max(pitchHi, p.pitchDeg + h / 2)
        }
        return (yawDeg: (yawLo + yawHi) / 2, pitchDeg: (pitchLo + pitchHi) / 2)
    }

    /// A flat screen's height as seen from the head, degrees: [widthDeg] wide with [aspect] width / height.
    public static func heightDeg(widthDeg: Double, aspect: Double) -> Double {
        let w = min(max(widthDeg, 0.1), 179)
        let a = max(aspect, 0.01)
        return 2 * atan(tan(w * .pi / 360) / a) * 180 / .pi
    }

    // MARK: - Each arrangement

    /// The first screen [widthDeg] wide, the others in a column to its right: one at 0.6 of the main screen's width
    /// level with its middle, or two to five at 0.5 one above the other, 2 degrees apart, the column's middle level with
    /// the main screen's. The whole block is centred. All shrink together if the column would pass 35 degrees up.
    private static func mainSide(aspects: [Double], widthDeg: Double, distance: Double) -> [PanelPlacement] {
        let sides = Array(aspects.dropFirst())
        let share = sides.count <= 1 ? sideShare : sideShareTwo
        let mainAspect = aspects[0]
        let s = fitScale { k in
            let mainH = heightDeg(widthDeg: widthDeg * k, aspect: mainAspect)
            let columnH = columnHeight(aspects: sides, widthDeg: widthDeg * share * k)
            return max(mainH, columnH)
        }
        let mainW = widthDeg * s
        let sideW = widthDeg * share * s
        let pitches = columnPitches(aspects: sides, widthDeg: sideW)
        // A screen tipped up or down reaches a little further sideways at its far corners than half its width:
        // the column stands off by that much, so its corners stay clear of the main screen.
        var sideHalf = sideW / 2
        for (i, a) in sides.enumerated() {
            let h = heightDeg(widthDeg: sideW, aspect: a)
            sideHalf = max(sideHalf, cornerReachDeg(widthDeg: sideW, heightDeg: h, pitchDeg: pitches[i]))
        }
        // Along the arc, right positive: the main screen's centre, then the column's, the block's middle at 0.
        let mainX = -(gapDeg + sideHalf + sideW / 2) / 2
        let columnX = mainX + mainW / 2 + gapDeg + sideHalf
        var out = [PanelPlacement(yawDeg: -mainX, widthDeg: mainW, aspect: mainAspect, distance: distance)]
        for (i, a) in sides.enumerated() {
            out.append(PanelPlacement(yawDeg: -columnX, pitchDeg: pitches[i], widthDeg: sideW, aspect: a, distance: distance))
        }
        return out
    }

    /// The screens one above another, the first on top, 2 degrees apart, the column centred on the horizon. Each is
    /// [widthDeg] wide unless the column would pass 35 degrees up or down: then all shrink together to fit.
    private static func stacked(aspects: [Double], widthDeg: Double, distance: Double) -> [PanelPlacement] {
        let s = fitScale { k in columnHeight(aspects: aspects, widthDeg: widthDeg * k) }
        let w = widthDeg * s
        let pitches = columnPitches(aspects: aspects, widthDeg: w)
        var out = [PanelPlacement]()
        for (i, a) in aspects.enumerated() {
            out.append(PanelPlacement(yawDeg: 0, pitchDeg: pitches[i], widthDeg: w, aspect: a, distance: distance))
        }
        return out
    }

    /// Four to six screens in two rows, the first half (the extra one with an odd count) on top, each row on an arc
    /// with its middle straight ahead, 2 degrees between screens and between the rows, the block centred on the
    /// horizon. Screens tipped up or down reach a little further sideways at their far corners, so each row is spaced
    /// by that much. All shrink together if the rows would pass 35 degrees up or down, or go round past 179 degrees.
    private static func twoRows(aspects: [Double], widthDeg: Double, distance: Double) -> [PanelPlacement] {
        let topCount = (aspects.count + 1) / 2
        let rows = [Array(aspects.prefix(topCount)), Array(aspects.dropFirst(topCount))]
        func rowHeight(_ r: [Double], _ w: Double) -> Double { r.map { heightDeg(widthDeg: w, aspect: $0) }.max() ?? 0 }
        func pitches(_ w: Double) -> [Double] {
            let top = rowHeight(rows[0], w)
            let bottom = rowHeight(rows[1], w)
            let half = (top + gapDeg + bottom) / 2
            return [half - top / 2, -half + bottom / 2]
        }
        // From one screen's centre to the next in a row: as wide as its far corners reach, plus the gap.
        func step(_ r: [Double], _ w: Double, _ pitch: Double) -> Double {
            var half = w / 2
            for a in r {
                half = max(half, cornerReachDeg(widthDeg: w, heightDeg: heightDeg(widthDeg: w, aspect: a), pitchDeg: pitch))
            }
            return 2 * half + gapDeg
        }
        let tall = fitScale { k in rowHeight(rows[0], widthDeg * k) + gapDeg + rowHeight(rows[1], widthDeg * k) }
        let round = fitScale(limit: 2 * maxYawDeg) { k in
            let w = widthDeg * k
            let p = pitches(w)
            return (0..<2).map { i in step(rows[i], w, p[i]) * Double(rows[i].count) - gapDeg }.max() ?? 0
        }
        let w = widthDeg * min(tall, round)
        let p = pitches(w)
        var out = [PanelPlacement]()
        for (i, r) in rows.enumerated() {
            let s = step(r, w, p[i])
            let first = s * Double(r.count - 1) / 2
            for (j, a) in r.enumerated() {
                out.append(PanelPlacement(yawDeg: first - s * Double(j), pitchDeg: p[i], widthDeg: w, aspect: a, distance: distance))
            }
        }
        return out
    }

    /// The first screen far away and large: 4.2 m wide at 5 m for a width setting of 40 degrees (45.6 degrees as
    /// seen), wider or narrower with the setting. Any other screens flank it at the user's distance, 0.6 of the
    /// width setting each: one to its right, or the second to its left and the third to its right, and with 4 to 6
    /// screens the rest further out the same way, left then right. The block is centred, so with two screens the big
    /// one sits a little left of straight ahead. With many flanks all shrink together so none goes round past 179
    /// degrees.
    private static func theater(aspects: [Double], widthDeg: Double, distance: Double) -> [PanelPlacement] {
        let mainAspect = aspects[0]
        let others = Array(aspects.dropFirst())
        let tall = fitScale { k in
            var h = heightDeg(widthDeg: theaterWidthDeg(widthDeg: widthDeg * k), aspect: mainAspect)
            for a in others {
                h = max(h, heightDeg(widthDeg: widthDeg * theaterFlankShare * k, aspect: a))
            }
            return h
        }
        // The whole block's width round the head: the big screen and every flank, 2 degrees apart.
        let flanks = Double(others.count)
        let round = others.count <= 2 ? 1 : fitScale(limit: 2 * maxYawDeg) { k in
            theaterWidthDeg(widthDeg: widthDeg * k) + flanks * (gapDeg + widthDeg * theaterFlankShare * k)
        }
        let s = min(tall, round)
        let mainW = theaterWidthDeg(widthDeg: widthDeg * s)
        let flankW = widthDeg * theaterFlankShare * s
        let step = mainW / 2 + gapDeg + flankW / 2 // from the big screen's centre to a flank's
        if others.isEmpty {
            return [PanelPlacement(yawDeg: 0, widthDeg: mainW, aspect: mainAspect, distance: theaterDistance)]
        }
        if others.count == 1 {
            // Big screen and one flank: the pair's middle straight ahead.
            let mainX = -(gapDeg + flankW) / 2
            return [
                PanelPlacement(yawDeg: -mainX, widthDeg: mainW, aspect: mainAspect, distance: theaterDistance),
                PanelPlacement(yawDeg: -(mainX + step), widthDeg: flankW, aspect: others[0], distance: distance),
            ]
        }
        var out = [PanelPlacement(yawDeg: 0, widthDeg: mainW, aspect: mainAspect, distance: theaterDistance)]
        for (i, a) in others.enumerated() {
            let yaw = step + Double(i / 2) * (flankW + gapDeg) // left for the 1st, 3rd, 5th flank; right for the others
            out.append(PanelPlacement(yawDeg: i % 2 == 0 ? yaw : -yaw, widthDeg: flankW, aspect: a, distance: distance))
        }
        // One flank more on the left (3 or 5 of them): the block's middle straight ahead, as with two screens.
        let mid = middle(out).yawDeg
        for i in out.indices { out[i].yawDeg -= mid }
        return out
    }

    // MARK: - Helpers

    /// The big screen's width as seen, degrees, for a width setting of [widthDeg].
    private static func theaterWidthDeg(widthDeg: Double) -> Double {
        let metres = theaterWidthMetres * widthDeg / defaultWidthDeg
        return 2 * atan(metres / 2 / theaterDistance) * 180 / .pi
    }

    /// The height of a column of screens, each [widthDeg] wide, 2 degrees apart, degrees.
    private static func columnHeight(aspects: [Double], widthDeg: Double) -> Double {
        var total = gapDeg * Double(max(aspects.count - 1, 0))
        for a in aspects {
            total += heightDeg(widthDeg: widthDeg, aspect: a)
        }
        return total
    }

    /// The pitch of each screen of a column centred on the horizon, the first on top.
    private static func columnPitches(aspects: [Double], widthDeg: Double) -> [Double] {
        var top = columnHeight(aspects: aspects, widthDeg: widthDeg) / 2
        var out = [Double]()
        for a in aspects {
            let h = heightDeg(widthDeg: widthDeg, aspect: a)
            out.append(top - h / 2)
            top -= h + gapDeg
        }
        return out
    }

    /// How far sideways from its centre, degrees of yaw, the far corners of a flat screen reach once it is tipped
    /// [pitchDeg] up or down. Level, that is half its width.
    private static func cornerReachDeg(widthDeg: Double, heightDeg: Double, pitchDeg: Double) -> Double {
        let tx = tan(widthDeg * .pi / 360)
        let ty = tan(heightDeg * .pi / 360)
        let p = abs(pitchDeg) * .pi / 180
        let depth = cos(p) - ty * sin(p)
        if depth <= 1e-6 { return 90 }
        return atan(tx / depth) * 180 / .pi
    }

    /// The largest scale, at most 1, at which [extent] (the arrangement's whole height in degrees at that scale)
    /// stays inside 35 degrees up and down, or inside another [limit] (a whole width round the head).
    private static func fitScale(limit: Double = 2 * maxPitchDeg, _ extent: (Double) -> Double) -> Double {
        if extent(1) <= limit { return 1 }
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if extent(mid) <= limit {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }
}

public enum SpaceMath {
    /// A rotation matrix from a quaternion.
    public static func rotation(_ q: Quat) -> simd_float4x4 {
        let m = q.matrix
        return simd_float4x4(columns: (
            SIMD4(m[0], m[1], m[2], m[3]),
            SIMD4(m[4], m[5], m[6], m[7]),
            SIMD4(m[8], m[9], m[10], m[11]),
            SIMD4(m[12], m[13], m[14], m[15])
        ))
    }

    /// Metal's perspective projection (clip z 0...1), vertical field [fovYDeg], [aspect] width / height.
    public static func perspective(fovYDeg: Double, aspect: Double, near: Double = 0.05, far: Double = 100) -> simd_float4x4 {
        let y = Float(1 / tan(fovYDeg * .pi / 360))
        let x = y / Float(aspect)
        let n = Float(near), f = Float(far)
        let z = f / (n - f)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * n, 0)
        ))
    }

    /// The view matrix for one eye: the head's rotation undone, then the eye's offset ([eyeX] metres, right positive).
    public static func view(head: Quat, eyeX: Double) -> simd_float4x4 {
        var shift = matrix_identity_float4x4
        shift.columns.3 = SIMD4(Float(-eyeX), 0, 0, 1)
        return shift * rotation(head.conjugate)
    }
}
