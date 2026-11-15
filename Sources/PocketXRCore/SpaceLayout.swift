import Foundation
import simd

/// Where one screen sits in the Space: a flat panel facing the head, at [distance] metres, turned [yawDeg] (left
/// positive) and [pitchDeg] (up positive), [widthDeg] wide. Its height follows the screen's aspect.
public struct PanelPlacement: Equatable, Sendable {
    public var yawDeg: Double
    public var pitchDeg: Double
    public var widthDeg: Double
    public var aspect: Double // width / height
    public var distance: Double

    public init(yawDeg: Double, pitchDeg: Double = 0, widthDeg: Double, aspect: Double, distance: Double) {
        self.yawDeg = yawDeg
        self.pitchDeg = pitchDeg
        self.widthDeg = widthDeg
        self.aspect = aspect
        self.distance = distance
    }

    /// Width and height in metres at its distance.
    public var sizeMetres: SIMD2<Double> {
        let w = 2 * distance * tan(widthDeg * .pi / 360)
        return SIMD2(w, w / aspect)
    }

    /// Model matrix: a unit quad (-0.5...0.5) scaled to the panel, pushed out to its distance, turned into place.
    public var modelMatrix: simd_float4x4 {
        let s = sizeMetres
        let scale = simd_float4x4(diagonal: SIMD4(Float(s.x), Float(s.y), 1, 1))
        var push = matrix_identity_float4x4
        push.columns.3 = SIMD4(0, 0, Float(-distance), 1)
        let turn = SpaceMath.rotation(Quat.aboutY(yawDeg * .pi / 180) * Quat.aboutX(pitchDeg * .pi / 180))
        return turn * push * scale
    }
}

/// The Space's layout and settings, as Pocket XR's PanelLayout has them (numbers from the Deck's space.py).
public enum SpaceLayout {
    public static let defaultDistance = 1.4
    public static let defaultWidthDeg = 40.0
    public static let gapDeg = 2.0
    public static let minDistance = 0.5
    public static let maxDistance = 6.0
    public static let minWidthDeg = 15.0
    public static let maxWidthDeg = 90.0

    /// [count] screens side by side on an arc around the head, the middle one straight ahead. Each angular width is
    /// [widthDeg]; [aspects] gives each screen's width / height.
    public static func row(aspects: [Double], widthDeg: Double, distance: Double, gapDeg: Double = gapDeg) -> [PanelPlacement] {
        let n = aspects.count
        guard n > 0 else { return [] }
        let step = widthDeg + gapDeg
        let first = step * Double(n - 1) / 2 // the leftmost, left positive
        return aspects.enumerated().map { i, aspect in
            PanelPlacement(yawDeg: first - step * Double(i), widthDeg: widthDeg, aspect: aspect, distance: distance)
        }
    }

    /// The middle of the row, for a recentre: 0 with the middle screen ahead.
    public static func middleYawDeg(_ panels: [PanelPlacement]) -> Double {
        guard let a = panels.first?.yawDeg, let b = panels.last?.yawDeg else { return 0 }
        return (a + b) / 2
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
