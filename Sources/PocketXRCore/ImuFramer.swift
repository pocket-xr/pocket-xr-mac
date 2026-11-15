import Foundation

/// One motion sample from the glasses: time in nanoseconds, gyro in rad/s, accelerometer in m/s².
public struct ImuSample: Equatable, Sendable {
    public var timestampNs: UInt64
    public var gyro: SIMD3<Double>
    public var accel: SIMD3<Double>
    public var temperature: Double

    public init(timestampNs: UInt64, gyro: SIMD3<Double>, accel: SIMD3<Double>, temperature: Double = 0) {
        self.timestampNs = timestampNs
        self.gyro = gyro
        self.accel = accel
        self.temperature = temperature
    }
}

/// The XREAL One family's and Aura's sensor stream, TCP 169.254.2.1:52998, read only.
///
/// Ported from Pocket XR for Steam Deck's imu.py, itself written from Pocket XR's notes on the public protocol (MIT
/// projects, credited in Pocket XR's docs/LICENSES.md). Frame: magic 0x28 0x36 (some firmware 0x27 0x36), u32 big
/// endian body length, body. Sensor reports have a 128 byte little endian body: 0x08 timestamp ns u64, 0x18 type u32
/// (0x0B IMU, 0x04 magnetometer), 0x1C gyro xyz f32 rad/s, 0x28 accel xyz f32, 0x40 temperature f32.
public final class ImuFramer {
    public static let host = "169.254.2.1"
    public static let ecmHost = "169.254.1.1"
    public static let port: UInt16 = 52998
    public static let header = 6
    public static let body = 128
    public static let typeImu: UInt32 = 0x0B

    private var buf = [UInt8]()
    public private(set) var reports = 0
    public private(set) var imu = 0
    public private(set) var dropped = 0
    public private(set) var badLength = 0

    public init() {}

    /// Takes the next bytes read from the socket and returns the IMU samples completed by them.
    public func feed(_ chunk: [UInt8]) -> [ImuSample] {
        buf.append(contentsOf: chunk)
        var out = [ImuSample]()
        var pos = 0
        let n = buf.count
        while n - pos >= Self.header {
            let m0 = buf[pos]
            guard (m0 == 0x28 || m0 == 0x27) && buf[pos + 1] == 0x36 else {
                pos += 1
                dropped += 1
                continue
            }
            let length = Int(Self.u32be(buf, pos + 2))
            guard length == Self.body else {
                pos += 1
                badLength += 1
                continue
            }
            if n - pos < Self.header + Self.body { break }
            let at = pos + Self.header
            if Self.u32le(buf, at + 0x18) == Self.typeImu {
                out.append(ImuSample(
                    timestampNs: Self.u64le(buf, at + 0x08),
                    gyro: SIMD3(Self.f32le(buf, at + 0x1C), Self.f32le(buf, at + 0x20), Self.f32le(buf, at + 0x24)),
                    accel: SIMD3(Self.f32le(buf, at + 0x28), Self.f32le(buf, at + 0x2C), Self.f32le(buf, at + 0x30)),
                    temperature: Self.f32le(buf, at + 0x40)
                ))
                imu += 1
            }
            reports += 1
            pos += Self.header + Self.body
        }
        buf.removeFirst(pos)
        if buf.count > 65536 {
            dropped += buf.count - 65536
            buf.removeFirst(buf.count - 65536)
        }
        return out
    }

    /// One frame, for tests and the fake source.
    public static func encode(_ s: ImuSample, type: UInt32 = ImuFramer.typeImu, magic0: UInt8 = 0x28) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: body)
        putU64le(&b, 0, 1)
        putU64le(&b, 0x08, s.timestampNs)
        putU32le(&b, 0x18, type)
        for i in 0..<3 {
            putU32le(&b, 0x1C + 4 * i, Float(s.gyro[i]).bitPattern)
            putU32le(&b, 0x28 + 4 * i, Float(s.accel[i]).bitPattern)
        }
        putU32le(&b, 0x40, Float(s.temperature).bitPattern)
        return [magic0, 0x36, 0, 0, 0, UInt8(body)] + b
    }

    // MARK: bytes

    static func u32be(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func u32le(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    static func u64le(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(u32le(b, i)) | UInt64(u32le(b, i + 4)) << 32
    }

    static func f32le(_ b: [UInt8], _ i: Int) -> Double { Double(Float(bitPattern: u32le(b, i))) }

    static func putU32le(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        for k in 0..<4 { b[i + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(k))) }
    }

    static func putU64le(_ b: inout [UInt8], _ i: Int, _ v: UInt64) {
        for k in 0..<8 { b[i + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) }
    }
}
