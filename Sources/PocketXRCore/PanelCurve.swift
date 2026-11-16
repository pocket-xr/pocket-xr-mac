import Foundation
import simd

/// One corner of a screen's drawing mesh: where it is in head-centred space (x right, y up, z back, metres) and
/// which point of the picture it shows (uv, (0, 0) the picture's top left).
public struct PanelVertex: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var uv: SIMD2<Float>

    public init(position: SIMD3<Float>, uv: SIMD2<Float>) {
        self.position = position
        self.uv = uv
    }
}

/// A curved screen, as Pocket XR's PanelCurve has it ("like an ultrawide curved monitor").
///
/// A screen's curve runs from 0 (flat) to 2.5. It bends the screen round a vertical cylinder (the axis along the
/// screen's own up) of radius distance / curve, whose axis is on the user's side of the screen. At 1 the axis passes
/// through the head, so every column is the same distance from the eyes. Past 1 the axis is in front of the head and
/// the edges come clearly forward. The angular width stays the screen's widthDeg at any curve: the edges are bent
/// forward until each is seen half that angle from the centre, so a curve never makes a screen look wider or
/// narrower, only rounder.
public enum PanelCurve {
    /// At or under this a curve is drawn and hit tested flat.
    public static let flatEps = 0.005
    /// The strongest curve.
    public static let maxCurve = 2.5
    /// The furthest an edge bends round its axis, degrees (a wide screen is held to it), so no edge turns past side on.
    public static let maxHalfArcDeg = 85.0
    /// 64 columns: the widest screen (100 degrees) at full curve is 1.6 degrees of arc a column, whose chord sits a
    /// small fraction of a glasses pixel off the arc.
    public static let defaultColumns = 64

    /// Half the screen's angular width, radians (held to 1...179 degrees whole).
    private static func halfWidth(_ widthDeg: Double) -> Double {
        let w = Swift.min(Swift.max(widthDeg, 1), 179)
        return w * .pi / 360
    }

    /// The curve a screen is drawn with: [curve] inside 0...2.5, held so its half arc stays under 85 degrees
    /// (phi = a + asin(sin(a)(c - 1)) reaches 85 degrees at c = 1 + sin(85 degrees - a) / sin(a)).
    public static func effective(curve: Double, widthDeg: Double) -> Double {
        let c = Swift.min(Swift.max(curve, 0), maxCurve)
        if c <= 1 { return c }
        let a = halfWidth(widthDeg)
        let limit = maxHalfArcDeg * .pi / 180
        if a >= limit { return 1 }
        return Swift.min(c, 1 + sin(limit - a) / sin(a))
    }

    public static func isCurved(_ p: PanelPlacement) -> Bool {
        p.curve > flatEps
    }

    /// The cylinder's radius, metres (infinite when flat).
    public static func radius(_ p: PanelPlacement) -> Double {
        if !isCurved(p) { return Double.infinity }
        return p.distance / effective(curve: p.curve, widthDeg: p.widthDeg)
    }

    /// Half the screen's arc around the axis, radians (0 when flat). With half the screen's angular width a, an edge
    /// at arc angle phi is at R sin(phi) across and R (1 - cos(phi)) nearer, and is seen at a from the head when
    /// phi = a - asin(sin(a)(1 - c)). At c = 1 phi = a.
    public static func halfArc(_ p: PanelPlacement) -> Double {
        if !isCurved(p) { return 0 }
        let a = halfWidth(p.widthDeg)
        let c = effective(curve: p.curve, widthDeg: p.widthDeg)
        let s = Swift.min(Swift.max(sin(a) * (1 - c), -1), 1)
        return a - asin(s)
    }

    /// The surface point at [x] (-0.5 at the left edge to 0.5 at the right, along the arc) and [y] (-0.5 bottom to
    /// 0.5 top, straight up the cylinder), before the screen is turned into place: the screen's centre is at
    /// (0, 0, -distance), its right is +x, its up +y, and the head is at the origin.
    public static func localPoint(_ p: PanelPlacement, x: Double, y: Double) -> SIMD3<Double> {
        let size = p.sizeMetres
        if !isCurved(p) {
            return SIMD3<Double>(x * size.x, y * size.y, -p.distance)
        }
        let r = radius(p)
        let th = x * 2 * halfArc(p)
        // The axis is at (0, -distance + r) in x and z; the surface is r from it, on the far side.
        return SIMD3<Double>(r * sin(th), y * size.y, -p.distance + r - r * cos(th))
    }

    /// The same point with the screen turned into place by its yaw and pitch, in head-centred space.
    public static func point(_ p: PanelPlacement, x: Double, y: Double) -> SIMD3<Double> {
        p.turn.rotate(localPoint(p, x: x, y: y))
    }

    /// Where a ray from the head meets the screen's surface (a cylinder when curved, else its plane): the distance
    /// along the ray and the fractions there, x -0.5 left to 0.5 right and y -0.5 bottom to 0.5 top (past those the
    /// ray passes beside the screen). [direction] is in head-centred space and need not be a unit vector. nil when
    /// the ray never meets the surface in front of the head.
    public static func intersect(_ p: PanelPlacement, direction: SIMD3<Double>) -> (t: Double, x: Double, y: Double)? {
        // The ray in the screen's own frame.
        let d = p.turn.conjugate.rotate(direction)
        let size = p.sizeMetres
        if size.x <= 0 || size.y <= 0 { return nil }
        if !isCurved(p) {
            if d.z > -1e-9 { return nil }
            let t = -p.distance / d.z
            return (t: t, x: d.x * t / size.x, y: d.y * t / size.y)
        }
        let r = radius(p)
        let half = halfArc(p)
        if half <= 0 { return nil }
        // From the axis to the head, across (x) and along the screen's normal (z, toward the head).
        let qz = p.distance - r
        let a = d.x * d.x + d.z * d.z
        if a < 1e-12 { return nil }
        let b = 2 * qz * d.z
        let c = qz * qz - r * r
        let disc = b * b - 4 * a * c
        if disc < 0 { return nil }
        let s = disc.squareRoot()
        // The stable form of the two roots.
        let k = -0.5 * (b + (b >= 0 ? s : -s))
        var roots: [Double] = [k / a]
        if k != 0 { roots.append(c / k) }
        roots.sort()
        for t in roots {
            if t <= 1e-6 { continue }
            let px = t * d.x
            let pz = qz + t * d.z
            // The screen's half of the cylinder is the far one.
            if pz >= 0 { continue }
            let th = atan2(px, -pz)
            return (t: t, x: th / (2 * half), y: t * d.y / size.y)
        }
        return nil
    }
}

public extension PanelPlacement {
    /// The screen as a triangle strip in head-centred space (x right, y up, z back, metres), uv (0, 0) at the
    /// picture's top left.
    ///
    /// Flat: 4 vertices, the unit quad's corners times `modelMatrix`, in the renderer's order (bottom left, bottom
    /// right, top left, top right). Curved: bent round a vertical cylinder as Pocket XR's PanelCurve does (radius
    /// distance / curve, angular width kept, half arc at most 85 degrees), [columns] columns from left to right,
    /// each column's top vertex then its bottom one (2 * (columns + 1) vertices), then turned into place by yaw and
    /// pitch. Both wind the same way (counter clockwise seen from the head).
    func mesh(columns: Int = 64) -> [PanelVertex] {
        if !PanelCurve.isCurved(self) {
            let m = modelMatrix
            let corners: [SIMD2<Float>] = [
                SIMD2<Float>(-0.5, -0.5), SIMD2<Float>(0.5, -0.5), SIMD2<Float>(-0.5, 0.5), SIMD2<Float>(0.5, 0.5),
            ]
            var flat = [PanelVertex]()
            flat.reserveCapacity(4)
            for c in corners {
                let q: SIMD4<Float> = m * SIMD4<Float>(c.x, c.y, 0, 1)
                let uv = SIMD2<Float>(c.x + 0.5, 0.5 - c.y)
                flat.append(PanelVertex(position: SIMD3<Float>(q.x, q.y, q.z), uv: uv))
            }
            return flat
        }
        let n = Swift.max(columns, 1)
        let t = turn
        var out = [PanelVertex]()
        out.reserveCapacity(2 * (n + 1))
        for i in 0...n {
            let f = Double(i) / Double(n)
            let top = t.rotate(PanelCurve.localPoint(self, x: f - 0.5, y: 0.5))
            let bottom = t.rotate(PanelCurve.localPoint(self, x: f - 0.5, y: -0.5))
            out.append(PanelVertex(
                position: SIMD3<Float>(Float(top.x), Float(top.y), Float(top.z)),
                uv: SIMD2<Float>(Float(f), 0)
            ))
            out.append(PanelVertex(
                position: SIMD3<Float>(Float(bottom.x), Float(bottom.y), Float(bottom.z)),
                uv: SIMD2<Float>(Float(f), 1)
            ))
        }
        return out
    }
}
