import Foundation

/// A rotation, w first. Head axes are x right, y up, z back (Metal's and OpenGL's view space), as in Pocket XR.
public struct Quat: Equatable, Sendable {
    public var w: Double, x: Double, y: Double, z: Double

    public init(_ w: Double, _ x: Double, _ y: Double, _ z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    public static let identity = Quat(1, 0, 0, 0)

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    public var conjugate: Quat { Quat(w, -x, -y, -z) }

    public var normalized: Quat {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return n > 0 ? Quat(w / n, x / n, y / n, z / n) : .identity
    }

    /// [v] turned by this rotation.
    public func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let p = self * Quat(0, v.x, v.y, v.z) * conjugate
        return SIMD3(p.x, p.y, p.z)
    }

    /// A turn of [angle] radians about the up axis (left positive).
    public static func aboutY(_ angle: Double) -> Quat { Quat(cos(angle / 2), 0, sin(angle / 2), 0) }

    /// A turn of [angle] radians about the right axis (up positive).
    public static func aboutX(_ angle: Double) -> Quat { Quat(cos(angle / 2), sin(angle / 2), 0, 0) }

    /// The turn about the world's up axis, radians, left positive.
    public var yaw: Double {
        let f = rotate(SIMD3(0, 0, -1))
        return atan2(-f.x, -f.z)
    }

    /// Column-major 4x4 rotation matrix, for Metal.
    public var matrix: [Float] {
        [
            Float(1 - 2 * (y * y + z * z)), Float(2 * (x * y + w * z)), Float(2 * (x * z - w * y)), 0,
            Float(2 * (x * y - w * z)), Float(1 - 2 * (x * x + z * z)), Float(2 * (y * z + w * x)), 0,
            Float(2 * (x * z + w * y)), Float(2 * (y * z - w * x)), Float(1 - 2 * (x * x + y * y)), 0,
            0, 0, 0, 1,
        ]
    }
}
