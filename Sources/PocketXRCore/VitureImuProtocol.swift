import Foundation

/// VITURE's glasses carry their IMU over USB HID on VITURE's own vendor id, 0x35CA. Ported from Pocket XR's
/// VitureImuProtocol, which was written from one public, MIT licensed protocol write-up (elasticjava/viture-v2's
/// PROTOCOL.md, measured on a VITURE Pro 2). No VITURE SDK code and no closed library is used. Experimental: the
/// project has run it on no VITURE glasses on a Mac.
///
/// A frame (one 64 byte HID report, zero padded, all little endian):
///
///   0  preamble 0x0010, u16
///   2  message id, u16
///   4  payload length, u16
///   6  checksum, u16: the plain sum of the payload's bytes, mod 65536
///   8  payload
///
/// 0x0301 (IMU control), payload 2 bytes: which streams (0x01 fused pose, 0x02 raw gyro and accelerometer, 0 off) and
/// a rate index, 0 the slowest (60 Hz) to 5 the fastest; index 2 is 120 Hz. Starting and stopping the raw stream is
/// the only thing Pocket XR ever sends to these glasses.
///
/// 0x7309 (a raw sample), payload: 4 u32 sample counter, 10 gyro x, y, z as f32 in rad/s, 22 accelerometer x, y, z as
/// f32 in g.
///
/// Axes: the write-up does not say which way the sensor's axes point, so the sensor's x, y, z are passed on as they
/// are. Pocket XR takes the Beast as x right, y down, z front (HeadFusion's `.one`, which Glasses.axes gives for it).
public enum VitureImuProtocol {
    public static let vendor = 0x35CA
    public static let packetBytes = 64
    public static let headerBytes = 8
    public static let preamble = 0x0010

    public static let msgImuControl = 0x0301
    public static let msgPose = 0x7308
    public static let msgRaw = 0x7309

    public static let streamOff: UInt8 = 0x00
    public static let streamRaw: UInt8 = 0x02
    /// The rate index the write-up shows working (120 Hz).
    public static let rate120: UInt8 = 2
    /// The smallest raw payload holding the gyro and the accelerometer.
    public static let rawMinPayload = 34
    /// The Beast's motion sensor is on HID interface 5 (found on the Deck); other models are tried interface by interface.
    public static let beastImuInterface = 5

    public struct Frame: Equatable, Sendable {
        public var msgId: Int
        public var payload: [UInt8]
    }

    /// One raw sample: the counter, the gyro in rad/s and the accelerometer in g, in the sensor's own axes.
    public struct RawSample: Equatable, Sendable {
        public var counter: UInt32
        public var gyro: SIMD3<Double>
        public var accelG: SIMD3<Double>
    }

    /// The plain byte sum of [count] bytes of [bytes] from [from], mod 65536.
    public static func checksum(_ bytes: [UInt8], from: Int = 0, count: Int? = nil) -> Int {
        let n: Int = count ?? (bytes.count - from)
        var s = 0
        var i = from
        while i < from + n {
            s += Int(bytes[i])
            i += 1
        }
        return s & 0xFFFF
    }

    /// A frame for [msgId] with [payload], header and payload only ([padded] makes it a 64 byte report). Kept
    /// internal: the app only ever sends [startRaw] and [stop].
    static func frame(_ msgId: Int, _ payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= packetBytes - headerBytes, "payload too long")
        var p = [UInt8](repeating: 0, count: headerBytes)
        put16(&p, 0, preamble)
        put16(&p, 2, msgId)
        put16(&p, 4, payload.count)
        put16(&p, 6, checksum(payload))
        return p + payload
    }

    /// [frame] zero padded to one 64 byte HID report.
    public static func padded(_ frame: [UInt8]) -> [UInt8] {
        frame.count >= packetBytes ? frame : frame + [UInt8](repeating: 0, count: packetBytes - frame.count)
    }

    /// The command that starts the raw gyro and accelerometer stream at 120 Hz (header and payload only).
    public static func startRaw() -> [UInt8] { frame(msgImuControl, [streamRaw, rate120]) }

    /// The command that stops every IMU stream.
    public static func stop() -> [UInt8] { frame(msgImuControl, [streamOff, 0]) }

    /// The frame in [packet], or nil when the preamble, the length or the checksum is wrong.
    public static func readFrame(_ packet: [UInt8]) -> Frame? {
        guard packet.count >= headerBytes, u16(packet, 0) == preamble else { return nil }
        let len = u16(packet, 4)
        guard headerBytes + len <= packet.count else { return nil }
        guard checksum(packet, from: headerBytes, count: len) == u16(packet, 6) else { return nil }
        return Frame(msgId: u16(packet, 2), payload: Array(packet[headerBytes..<(headerBytes + len)]))
    }

    /// The raw sample in a 0x7309 [payload], or nil when it is too short or holds a value that is not a number.
    public static func parseRaw(_ payload: [UInt8]) -> RawSample? {
        guard payload.count >= rawMinPayload else { return nil }
        let gyro = SIMD3<Double>(ImuFramer.f32le(payload, 10), ImuFramer.f32le(payload, 14), ImuFramer.f32le(payload, 18))
        let accel = SIMD3<Double>(ImuFramer.f32le(payload, 22), ImuFramer.f32le(payload, 26), ImuFramer.f32le(payload, 30))
        guard finite(gyro), finite(accel) else { return nil }
        return RawSample(counter: ImuFramer.u32le(payload, 4), gyro: gyro, accelG: accel)
    }

    /// The raw sample of a whole 64 byte report (gyro in rad/s, accelerometer in g, the sensor's own axes; VitureClock
    /// gives its time from the counter). Nil when the report is not a raw sample.
    public static func parseReport(_ packet: [UInt8]) -> RawSample? {
        guard let f = readFrame(packet), f.msgId == msgRaw else { return nil }
        return parseRaw(f.payload)
    }

    /// [raw] as the fusion takes it: gyro in rad/s, accelerometer in m/s² (g times 9.81), axes as the sensor sends.
    public static func sample(_ raw: RawSample, timestampNs: UInt64) -> ImuSample {
        ImuSample(timestampNs: timestampNs, gyro: raw.gyro, accel: raw.accelG * AirImuProtocol.g)
    }

    /// Builds a 64 byte raw sample report, for the checks and a fake source.
    public static func encodeRaw(counter: UInt32, gyroRadS: SIMD3<Double>, accelG: SIMD3<Double>) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 46)
        ImuFramer.putU32le(&p, 4, counter)
        for k in 0..<3 {
            ImuFramer.putU32le(&p, 10 + 4 * k, Float(gyroRadS[k]).bitPattern)
            ImuFramer.putU32le(&p, 22 + 4 * k, Float(accelG[k]).bitPattern)
        }
        return padded(frame(msgRaw, p))
    }

    private static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    static func u16(_ p: [UInt8], _ i: Int) -> Int { Int(p[i]) | Int(p[i + 1]) << 8 }

    private static func put16(_ p: inout [UInt8], _ at: Int, _ v: Int) {
        p[at] = UInt8(v & 0xFF)
        p[at + 1] = UInt8((v >> 8) & 0xFF)
    }
}

/// The raw samples' times (Pocket XR's VitureClock). A sample carries only a counter, one a sample, so the time step
/// comes from the rate the glasses really send at, measured against the Mac's clock over the first 120 samples; until
/// then the asked for rate's. A counter that goes back (a restart) starts over.
public struct VitureClock: Sendable {
    public static let learnSamples: Int64 = 120

    private let nominalNs: Double
    private var firstCounter: Int64 = -1
    private var firstHostNs: UInt64 = 0
    private var lastCounter: Int64 = -1
    /// Ns a sample.
    public private(set) var periodNs: Double
    public private(set) var learned = false

    public init(nominalHz: Double = 120) {
        nominalNs = 1e9 / nominalHz
        periodNs = 1e9 / nominalHz
    }

    /// The sample's time, ns, from its [counter] and the Mac's [hostNs] when it came.
    public mutating func toNs(counter: UInt32, hostNs: UInt64) -> UInt64 {
        let c = Int64(counter)
        if firstCounter < 0 || c < lastCounter {
            firstCounter = c
            firstHostNs = hostNs
            learned = false
            periodNs = nominalNs
        }
        lastCounter = c
        let steps: Int64 = c - firstCounter
        if !learned && steps >= Self.learnSamples {
            let measured: Double = Double(hostNs &- firstHostNs) / Double(steps)
            // A rate off by more than a factor of 20 from what was asked is not believed.
            if measured > periodNs / 20 && measured < periodNs * 20 { periodNs = measured }
            learned = true
        }
        return firstHostNs &+ UInt64((Double(steps) * periodNs).rounded())
    }

    public var line: String {
        String(format: "%@ %.1f Hz", learned ? "samples measured at" : "samples taken as", 1e9 / periodNs)
    }
}
