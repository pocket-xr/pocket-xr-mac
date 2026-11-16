import Foundation

/// The XREAL control link, 169.254.2.1:52999, ported from Pocket XR for Steam Deck's control.py (itself rewritten
/// from Pocket XR's GlassesWire).
///
/// Frame: u16 type, u32 body length (both big endian), body. An RPC body is a u32 big endian id (top bit set on
/// requests) and a protobuf with the request in field 3 and the answer in field 4 (answer field 1 = result, 0 for done;
/// field 2 = the value; field 3 = a second value).
///
/// Only commands Pocket XR has proven on the Aura are here, and `sendable` refuses anything else.
/// Never 10079 (EDID), never 10325 to 10328 (firmware update), never a guessed id.
public enum ControlWire {
    public static let host = "169.254.2.1"
    public static let port: UInt16 = 52999

    public static let heartbeat = 10000
    public static let stereoGet = 10273, stereoSet = 10274 // 2D (0) / 3D side by side (1)
    public static let ultrawideGet = 10277, ultrawideSet = 10278
    public static let sizeRange = 10396, sizeGet = 10397, sizeSet = 10398
    public static let anchorGet = 10404, anchorSet = 10405 // Spatial Anchor
    public static let serialGet = 10025
    public static let spaceModeGet = 10421 // 1 follow, 0 (left out) hover
    public static let spaceMode = 10284 // set { 1: mode }: 1 follow
    public static let spaceFollow = 1
    public static let recenter = 10279 // empty request: in Ultrawide the glasses bring their canvas in front

    public static let sendable: Set<Int> = [
        heartbeat, stereoGet, stereoSet, ultrawideGet, ultrawideSet, sizeRange, sizeGet, sizeSet,
        anchorGet, anchorSet, serialGet, recenter, spaceModeGet, spaceMode,
    ]
    public static let forbidden: Set<Int> = [10079, 10325, 10326, 10327, 10328]
    public static let sets: Set<Int> = [stereoSet, ultrawideSet, sizeSet, anchorSet, recenter, spaceMode]

    public enum WireError: Error { case notSendable(Int) }

    // MARK: protobuf, just enough

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out = [UInt8]()
        repeat {
            let b = UInt8(v & 0x7F)
            v >>= 7
            out.append(v != 0 ? b | 0x80 : b)
        } while v != 0
        return out
    }

    /// Zero is left out, as proto3 and Pocket XR's ProtoWriter do: "off" is an empty request.
    public static func pbVarint(_ field: Int, _ v: Int) -> [UInt8] {
        v == 0 ? [] : varint(UInt64(field << 3)) + varint(UInt64(v))
    }

    public static func pbFloat(_ field: Int, _ f: Float) -> [UInt8] {
        let bits = f.bitPattern
        if bits == 0 { return [] }
        return varint(UInt64(field << 3 | 5)) + (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt32($0))) }
    }

    public static func pbMessage(_ field: Int, _ body: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(body.count)) + body
    }

    /// A parsed protobuf value: a varint, a 32 bit float, a 64 bit double, or bytes.
    public enum PbValue: Equatable, Sendable {
        case int(Int), f32(Float), f64(Double), bytes([UInt8])

        public var number: Double? {
            switch self {
            case .int(let v): return Double(v)
            case .f32(let v): return Double(v)
            case .f64(let v): return v
            case .bytes: return nil
            }
        }
    }

    /// field -> values, or nil if malformed.
    public static func pbParse(_ b: [UInt8]) -> [Int: [PbValue]]? {
        var out = [Int: [PbValue]]()
        var i = 0
        func readVarint() -> UInt64? {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count {
                let c = b[i]
                i += 1
                if shift < 64 { v |= UInt64(c & 0x7F) << shift }
                if c & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3), wire = Int(key & 7)
            let value: PbValue
            switch wire {
            case 0:
                guard let v = readVarint() else { return nil }
                value = .int(Int(truncatingIfNeeded: v))
            case 5:
                guard i + 4 <= b.count else { return nil }
                value = .f32(Float(bitPattern: ImuFramer.u32le(b, i)))
                i += 4
            case 1:
                guard i + 8 <= b.count else { return nil }
                value = .f64(Double(bitPattern: ImuFramer.u64le(b, i)))
                i += 8
            case 2:
                guard let n = readVarint(), n <= UInt64(b.count - i) else { return nil }
                value = .bytes(Array(b[i..<i + Int(n)]))
                i += Int(n)
            default:
                return nil
            }
            out[field, default: []].append(value)
        }
        return out
    }

    // MARK: frames

    public static func header(_ type: Int, _ length: Int) -> [UInt8] {
        [UInt8(type >> 8 & 0xFF), UInt8(type & 0xFF),
         UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
    }

    /// The heartbeat request: kind 1, then the host's time in ns; 33 bytes little endian.
    public static func heartbeatFrame(_ t1Ns: UInt64) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 33)
        body[0] = 1
        for k in 0..<8 { body[1 + k] = UInt8(truncatingIfNeeded: t1Ns >> (8 * UInt64(k))) }
        return header(heartbeat, body.count) + body
    }

    /// The RPC id of request number [counter]: the top bit set for a request.
    public static func rpcId(_ counter: Int) -> UInt32 { UInt32((counter + 1) & 0x7FFF_FFFF) | 0x8000_0000 }

    public static func rpc(_ type: Int, _ id: UInt32, _ request: [UInt8] = []) throws -> [UInt8] {
        guard sendable.contains(type), !forbidden.contains(type) else { throw WireError.notSendable(type) }
        let pb = pbMessage(3, request)
        let idBytes = [UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
        return header(type, 4 + pb.count) + idBytes + pb
    }

    public static func stereoSetFrame(_ id: UInt32, sbs: Bool) throws -> [UInt8] { try rpc(stereoSet, id, pbVarint(1, sbs ? 1 : 0)) }
    public static func ultrawideSetFrame(_ id: UInt32, on: Bool) throws -> [UInt8] { try rpc(ultrawideSet, id, pbVarint(1, on ? 1 : 0)) }
    public static func anchorSetFrame(_ id: UInt32, on: Bool) throws -> [UInt8] { try rpc(anchorSet, id, pbVarint(1, on ? 1 : 0)) }
    public static func sizeSetFrame(_ id: UInt32, size: Float) throws -> [UInt8] { try rpc(sizeSet, id, pbFloat(1, size)) }
    public static func followFrame(_ id: UInt32) throws -> [UInt8] { try rpc(spaceMode, id, pbVarint(1, spaceFollow)) }
    /// Recentre in Ultrawide (10279, an empty request): the glasses bring their own canvas in front of the head.
    public static func recenterFrame(_ id: UInt32) throws -> [UInt8] { try rpc(recenter, id) }

    /// Any screen size outside this is not believed, whatever range the glasses answer (Pocket XR's
    /// SCREEN_SIZE_LOWEST and SCREEN_SIZE_HIGHEST).
    public static let screenSizeLowest = 0.5
    public static let screenSizeHighest = 1.5

    /// A screen size the glasses answered (10397's value, or 10396's largest in its second value), if it can be
    /// believed: a number inside [screenSizeLowest, screenSizeHighest].
    public static func believableSize(_ v: Double?) -> Double? {
        guard let v = v, v.isFinite, v >= screenSizeLowest, v <= screenSizeHighest else { return nil }
        return v
    }

    /// An answer from the glasses.
    public struct Answer: Equatable, Sendable {
        public var type: Int
        public var id: UInt32
        public var result: Int
        public var value: Double?
        public var value2: Double?
        public var text: String?

        /// The value as a whole flag: an empty answer is 0 (proto3 leaves zero out).
        public var flag: Int { value.map { $0.isFinite && abs($0) < 1e9 ? Int($0) : 0 } ?? 0 }
    }

    /// Splits the control stream into answers, skipping heartbeats and the glasses' own requests.
    public final class Framer {
        private var buf = [UInt8]()
        public init() {}

        public func feed(_ chunk: [UInt8]) -> [Answer] {
            buf.append(contentsOf: chunk)
            var out = [Answer]()
            var pos = 0
            while buf.count - pos >= 6 {
                let type = Int(buf[pos]) << 8 | Int(buf[pos + 1])
                let n = Int(ImuFramer.u32be(buf, pos + 2))
                if n > 1 << 20 { pos += 1; continue }
                if buf.count - pos < 6 + n { break }
                let body = Array(buf[(pos + 6)..<(pos + 6 + n)])
                pos += 6 + n
                guard type != heartbeat, n >= 4 else { continue }
                let id = ImuFramer.u32be(body, 0)
                guard id & 0x8000_0000 == 0 else { continue } // answers have the top bit clear
                let fields = pbParse(Array(body[4...])) ?? [:]
                var resp = [Int: [PbValue]]()
                if case .bytes(let r)? = fields[4]?.last { resp = pbParse(r) ?? [:] }
                var result = 0
                if case .int(let r)? = resp[1]?.last { result = r }
                var text: String?
                if case .bytes(let t)? = resp[2]?.last { text = String(decoding: t, as: UTF8.self) }
                out.append(Answer(type: type, id: id, result: result, value: resp[2]?.last?.number,
                                  value2: resp[3]?.last?.number, text: text))
            }
            buf.removeFirst(pos)
            return out
        }
    }
}
