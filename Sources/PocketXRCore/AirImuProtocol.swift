import Foundation

/// The XREAL Air family's sensor stream, ported from Pocket XR's AirImuProtocol (written there from the publicly
/// documented protocol: ar-drivers-rs, MIT, and nrealAirLinuxDriver; none of their code). The Air, Air 2, Air 2 Pro
/// and Air 2 Ultra have no USB network: their IMU streams on a USB HID interface. Not yet run on Air glasses by the
/// project, on any system.
///
/// A command (64 bytes, to the IMU interface): 0xAA, a CRC32 (little endian) of everything from the length on, a
/// 2 byte little endian length (the payload's plus 3), the command id, the payload. 0x19 with payload 1 starts the
/// stream, with 0 stops it. That is the only command Pocket XR ever sends to these glasses.
///
/// A sensor report (64 bytes, from the IMU interface), little endian:
///
///   0x00  0x01 0x02
///   0x02  temperature, i16
///   0x04  timestamp, u64 (ns; AirTimestamp checks)
///   0x0C  gyro multiplier u16, divisor i32, then x, y, z as i24 (deg/s once multiplied and divided)
///   0x1B  accelerometer multiplier u16, divisor i32, then x, y, z as i24 (g; parse gives m/s², as the fusion expects)
///   0x2A  magnetometer (not used)
public enum AirImuProtocol {
    public static let packetBytes = 64
    public static let commandHead: UInt8 = 0xAA
    public static let cmdImuStream = 0x19
    /// The Air 2 Ultra, whose IMU is on HID interface 2.
    public static let air2Ultra = 0x0426
    /// The XBX A01 and A01+: the Air's protocol, 64 byte reports, the IMU on HID interface 1 (the MCU on 0), as
    /// nrealAirLinuxDriver's hid_ids.c (MIT) lists them. Untested by the project.
    public static let xbxA01 = 0x0440
    public static let xbxA01Plus = 0x0442
    /// m/s² in one g: the report's accelerometer unit to the fusion's.
    public static let g = 9.81

    /// The model's name for the log, or nil when [product] is not an Air family product with a known stream.
    public static func modelName(_ product: Int) -> String? { Glasses.airImu[product] }

    public static func isAir(vendor: Int, product: Int) -> Bool {
        vendor == Glasses.xreal && modelName(product) != nil
    }

    public static func isXbx(_ product: Int) -> Bool { product == xbxA01 || product == xbxA01Plus }

    // The XBX's MCU, on HID interface 0. wheaney's nrealAirLinuxDriver (mcu_hid.c, hid_ids.c, MIT; what XR Gaming uses)
    // marks the XBX A01 and A01+ as needing an MCU "heartbeat" before the IMU streams: a start-up handshake, then 0x1A
    // with the time every 100 ms (the sequence found by taowen's ar-glass-lib). A tester's A01+ sent nothing at all on
    // interface 1 without it (Pocket XR for Steam Deck 0.6.0, November 2026). Ported from Pocket XR for Steam Deck
    // 0.6.1's hidimu.py. Untested by the project.
    public static let xbxMcuInterface = 0
    public static let mcuHead: UInt8 = 0xFD
    public static let mcuHeartbeatId = 0x1A
    public static let mcuSdkVersion: [UInt8] = Array("3.1.1".utf8)
    /// The handshake, in order: 0x26, 0x57, 0x12 (1), 0x02 (1), 0x34, 0x35, then 0x31 with the SDK version.
    public static let mcuBootstrap: [(id: Int, data: [UInt8])] = [
        (0x26, []), (0x57, []), (0x12, [1, 0, 0, 0]), (0x02, [1, 0, 0, 0]), (0x34, []), (0x35, []), (0x31, mcuSdkVersion),
    ]

    /// An XREAL MCU frame: 0xFD, a CRC32 (little endian) of everything after it, the length (17 + data, u16), a
    /// timestamp (u64), the message id (u16), 5 reserved bytes, the data. Not padded.
    public static func mcuCommand(_ id: Int, _ data: [UInt8] = [], timestamp: UInt64 = 0) -> [UInt8] {
        let length = 17 + data.count
        var body = [UInt8]()
        body.append(UInt8(length & 0xFF)); body.append(UInt8((length >> 8) & 0xFF))
        for k in 0..<8 { body.append(UInt8(truncatingIfNeeded: timestamp >> (8 * UInt64(k)))) }
        body.append(UInt8(id & 0xFF)); body.append(UInt8((id >> 8) & 0xFF))
        body += [UInt8](repeating: 0, count: 5)
        body += data
        let crc = crc32(body)
        var out: [UInt8] = [mcuHead]
        for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: crc >> (8 * UInt32(k)))) }
        return out + body
    }

    /// The heartbeat: 0x1A with the time (ns) as its data.
    public static func mcuHeartbeat(nowNs: UInt64) -> [UInt8] {
        var t = [UInt8]()
        for k in 0..<8 { t.append(UInt8(truncatingIfNeeded: nowNs >> (8 * UInt64(k)))) }
        return mcuCommand(mcuHeartbeatId, t)
    }

    /// One step of looking for the stream.
    public enum Try: Equatable, Sendable {
        /// Ask this interface for the stream and wait for samples.
        case imu(Int)
        /// Ask this interface again, only if the MCU heartbeat is running.
        case imuWithMcu(Int)
        /// Wake the XBX's MCU (interface 0): the handshake, then the heartbeat.
        case wakeMcu
    }

    /// The steps, in order, for [product] with HID [interfaces] listed. Every model: its IMU interface. The XBX also:
    /// if that stays silent, the MCU woken and the IMU interface asked again, then each other interface (not the
    /// MCU's), lowest first, as Pocket XR for Steam Deck 0.6.1 does.
    public static func tryOrder(product: Int, interfaces: Set<Int>) -> [Try] {
        let wanted = imuInterface(product)
        var steps: [Try] = interfaces.contains(wanted) ? [.imu(wanted)] : []
        guard isXbx(product) else { return steps }
        if interfaces.contains(xbxMcuInterface) {
            steps.append(.wakeMcu)
            if interfaces.contains(wanted) { steps.append(.imuWithMcu(wanted)) }
        }
        for n in interfaces.sorted() where n != wanted && n != xbxMcuInterface { steps.append(.imu(n)) }
        return steps
    }

    /// The first [n] bytes in hex, for the log ("01 02 1f 00 ...").
    public static func hexStart(_ bytes: [UInt8], _ n: Int = 16) -> String {
        bytes.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ") + (bytes.count > n ? " ..." : "")
    }

    /// The HID interface the IMU streams on: 3 (Air, Air 2, Air 2 Pro), 2 on the Air 2 Ultra, 1 on the XBX A01 and A01+.
    public static func imuInterface(_ product: Int) -> Int {
        switch product {
        case air2Ultra: return 2
        case xbxA01, xbxA01Plus: return 1
        default: return 3
        }
    }

    /// CRC32 as zlib and java.util.zip.CRC32 compute it (polynomial 0xEDB88320, reflected), of [count] bytes from
    /// [from].
    public static func crc32(_ bytes: [UInt8], from: Int = 0, count: Int? = nil) -> UInt32 {
        let n: Int = count ?? (bytes.count - from)
        var crc: UInt32 = 0xFFFF_FFFF
        var i = from
        let end = from + n
        while i < end {
            crc ^= UInt32(bytes[i])
            for _ in 0..<8 {
                let lowBit: UInt32 = crc & 1
                crc >>= 1
                if lowBit != 0 { crc ^= 0xEDB8_8320 }
            }
            i += 1
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// A 64 byte command [id] with [data]. Kept internal: the app only ever sends [streamCommand].
    static func command(_ id: Int, _ data: [UInt8] = []) -> [UInt8] {
        precondition(data.count <= packetBytes - 8, "command payload too long")
        var p = [UInt8](repeating: 0, count: packetBytes)
        p[0] = commandHead
        let length = data.count + 3
        p[5] = UInt8(length & 0xFF)
        p[6] = UInt8((length >> 8) & 0xFF)
        p[7] = UInt8(id & 0xFF)
        for (k, b) in data.enumerated() { p[8 + k] = b }
        let crc = crc32(p, from: 5, count: length)
        for k in 0..<4 { p[1 + k] = UInt8(truncatingIfNeeded: crc >> (8 * UInt32(k))) }
        return p
    }

    /// The command that starts (or with [on] false, stops) the IMU stream.
    public static func streamCommand(on: Bool = true) -> [UInt8] { command(cmdImuStream, [on ? 1 : 0]) }

    /// Whether [packet] is a sensor report (not a command's answer, which starts 0xAA).
    public static func isReport(_ packet: [UInt8]) -> Bool {
        packet.count >= 0x2A && packet[0] == 0x01 && packet[1] == 0x02
    }

    /// The report in [packet] as a sample in head axes (x right, y up, z back: what HeadFusion's `.aura` takes as it
    /// is), gyro in rad/s and accelerometer in m/s², or nil when it is not a report or a divisor is 0. The sensor's own
    /// axes are x left, y back, z up, as ar-drivers-rs maps them (head x = -x, y = z, z = y); unconfirmed on glasses.
    /// The timestamp is the report's own, raw: AirTimestamp turns it into ns.
    public static func parse(_ packet: [UInt8]) -> ImuSample? {
        guard isReport(packet) else { return nil }
        let gMul = Double(u16(packet, 0x0C))
        let gDiv = i32(packet, 0x0E)
        let aMul = Double(u16(packet, 0x1B))
        let aDiv = i32(packet, 0x1D)
        if gDiv == 0 || aDiv == 0 { return nil }
        let gScale: Double = gMul / Double(gDiv) * Double.pi / 180
        // The report is in g, about 1 at rest, but the fusion works in m/s² (Pocket XR 1.2.3, issue 49).
        let aScale: Double = aMul / Double(aDiv) * g
        let gyro = SIMD3<Double>(Double(i24(packet, 0x12)) * gScale, Double(i24(packet, 0x15)) * gScale, Double(i24(packet, 0x18)) * gScale)
        let accel = SIMD3<Double>(Double(i24(packet, 0x21)) * aScale, Double(i24(packet, 0x24)) * aScale, Double(i24(packet, 0x27)) * aScale)
        return ImuSample(timestampNs: ImuFramer.u64le(packet, 0x04), gyro: toHead(gyro), accel: toHead(accel),
                         temperature: Double(i16(packet, 0x02)))
    }

    /// The sensor's axes (x left, y back, z up) in head axes (x right, y up, z back).
    public static func toHead(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3<Double>(-v.x, v.z, v.y) }

    /// Head axes back to the sensor's: the inverse of [toHead].
    public static func toSensor(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3<Double>(-v.x, v.z, v.y) }

    /// Builds a sensor report, for the checks and a fake source. Values are in the sensor's own axes, deg/s and g.
    public static func encodeReport(timestamp: UInt64, gyroDegS: SIMD3<Double>, accelG: SIMD3<Double>,
                                    gyroDiv: Int32 = 8192, accelDiv: Int32 = 8192) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetBytes)
        p[0] = 0x01
        p[1] = 0x02
        for k in 0..<8 { p[0x04 + k] = UInt8(truncatingIfNeeded: timestamp >> (8 * UInt64(k))) }
        put16(&p, 0x0C, 1)
        put32(&p, 0x0E, gyroDiv)
        put16(&p, 0x1B, 1)
        put32(&p, 0x1D, accelDiv)
        for k in 0..<3 {
            put24(&p, 0x12 + 3 * k, Int32((gyroDegS[k] * Double(gyroDiv)).rounded()))
            put24(&p, 0x21 + 3 * k, Int32((accelG[k] * Double(accelDiv)).rounded()))
        }
        return p
    }

    // MARK: bytes

    static func u16(_ p: [UInt8], _ i: Int) -> Int { Int(p[i]) | Int(p[i + 1]) << 8 }

    static func i16(_ p: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8)) }

    /// Three bytes, sign extended.
    static func i24(_ p: [UInt8], _ i: Int) -> Int {
        let raw: UInt32 = UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16
        return Int(Int32(bitPattern: raw << 8) >> 8)
    }

    static func i32(_ p: [UInt8], _ i: Int) -> Int { Int(Int32(bitPattern: ImuFramer.u32le(p, i))) }

    private static func put16(_ p: inout [UInt8], _ at: Int, _ v: Int) {
        p[at] = UInt8(v & 0xFF)
        p[at + 1] = UInt8((v >> 8) & 0xFF)
    }

    private static func put24(_ p: inout [UInt8], _ at: Int, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        for k in 0..<3 { p[at + k] = UInt8(truncatingIfNeeded: u >> (8 * UInt32(k))) }
    }

    private static func put32(_ p: inout [UInt8], _ at: Int, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        for k in 0..<4 { p[at + k] = UInt8(truncatingIfNeeded: u >> (8 * UInt32(k))) }
    }
}

/// The Air report's timestamp unit, from its first steps (Pocket XR's AirTimestamp). The public drivers read it as
/// ns; should a firmware send µs instead, every step would be 1000 times too short and the fusion would turn the view
/// by a thousandth of the head's turn. At about 1 kHz a step of under 50 000 can only be µs.
public struct AirTimestamp: Sendable {
    public static let microsBelow: UInt64 = 50_000

    private var last: UInt64?
    /// Ns per unit: 1 until decided, then 1 (ns) or 1000 (µs).
    public private(set) var scale: UInt64 = 1
    public private(set) var decided = false

    public init() {}

    public mutating func toNs(_ raw: UInt64) -> UInt64 {
        if !decided, let l = last, raw > l {
            scale = (raw - l) < Self.microsBelow ? 1000 : 1
            decided = true
        }
        last = raw
        return raw &* scale
    }

    public var line: String {
        if !decided { return "timestamps: unit not decided yet" }
        return scale == 1 ? "timestamps: ns" : "timestamps: µs (taken as ns x 1000)"
    }
}
