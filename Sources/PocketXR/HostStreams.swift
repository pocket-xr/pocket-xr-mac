import Foundation
import CryptoKit
import CHostNet
import PocketXRCore

/// Little and big endian writes into a byte buffer.
extension UnsafeMutablePointer where Pointee == UInt8 {
    func le16(_ at: Int, _ v: UInt16) { self[at] = UInt8(v & 0xFF); self[at + 1] = UInt8(v >> 8) }
    func le32(_ at: Int, _ v: UInt32) { for i in 0..<4 { self[at + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
    func be16(_ at: Int, _ v: UInt16) { self[at] = UInt8(v >> 8); self[at + 1] = UInt8(v & 0xFF) }
    func be32(_ at: Int, _ v: UInt32) { for i in 0..<4 { self[at + i] = UInt8((v >> (8 * UInt32(3 - i))) & 0xFF) } }
}

/// The host's video stream (Sunshine's videoBroadcastThread, via Pocket XR for Windows' HostVideo, GPLv3): each
/// encoded frame behind an 8-byte short header, cut into packets of the client's packet size, each with a 12-byte RTP
/// header (and 4 reserved bytes) and a 16-byte NV_VIDEO_PACKET header, in up to four FEC blocks with Reed-Solomon
/// parity (20 %, at least the client's minimum). Sent to where the client's pings come from. Unencrypted.
final class HostVideo: @unchecked Sendable {
    private static let rtpHeader = 16
    private static let headerSize = rtpHeader + 16
    private let udp: HostUdp
    private let packetSize, fecPercent, minParity: Int
    /// Packets sent so far: the RTP sequence is its low 16 bits, the stream packet index its low 24 (never back).
    private var lowSeq: UInt32 = 0
    private var frameIndex: UInt32 = 0
    private let epoch = DispatchTime.now().uptimeNanoseconds
    private(set) var framesSent = 0, packetsSent = 0, bytesSent = 0
    private var shards = [UInt8]()

    init?(port: Int, packetSize: Int, fecPercent: Int, minParity: Int, clientIp: String? = nil) {
        guard let u = HostUdp(port: port, name: "video", allowedIp: clientIp) else { return nil }
        udp = u
        self.packetSize = packetSize
        self.fecPercent = fecPercent
        self.minParity = minParity
    }

    var hasClient: Bool { udp.hasClient }
    var firstClient: (() -> Void)? {
        get { udp.firstClient }
        set { udp.firstClient = newValue }
    }

    /// One encoded frame out. [latency]: capture to sending, in 0.1 ms.
    func send(_ frame: [UInt8], idr: Bool, latency: Int) {
        guard udp.hasClient else { return }
        frameIndex &+= 1
        let blockSize = packetSize + Self.rtpHeader
        let perPacket = blockSize - Self.headerSize
        let dataLen = 8 + frame.count
        let packets = (dataLen + perPacket - 1) / perPacket
        var lastLen = dataLen % (packetSize - 16)
        if lastLen == 0 { lastLen = packetSize - 16 }
        var payload = [UInt8](repeating: 0, count: packets * Self.headerSize + dataLen)
        var head = [UInt8](repeating: 0, count: 8)
        head[0] = 0x01
        let lat = UInt16(max(0, min(65535, latency)))
        head[1] = UInt8(lat & 0xFF); head[2] = UInt8(lat >> 8)
        head[3] = idr ? 2 : 1
        head[4] = UInt8(lastLen & 0xFF); head[5] = UInt8((lastLen >> 8) & 0xFF)
        payload.withUnsafeMutableBufferPointer { out in
            frame.withUnsafeBufferPointer { f in
                var src = 0
                for p in 0..<packets {
                    let at = p * (Self.headerSize + perPacket) + Self.headerSize
                    let take = min(perPacket, dataLen - src)
                    var i = 0
                    while i < take && src < 8 { out[at + i] = head[src]; i += 1; src += 1 }
                    if i < take {
                        let n = take - i
                        memcpy(out.baseAddress! + at + i, f.baseAddress! + (src - 8), n)
                        src += n
                    }
                }
            }
        }
        var fec = fecPercent
        let maxDataShards = 255 * 100 / (100 + fec)
        let maxPerBlock = maxDataShards * blockSize
        var blocks = (payload.count + maxPerBlock - 1) / maxPerBlock
        if blocks > 4 { fec = 0; blocks = 4 }
        let unaligned = payload.count / blocks
        let aligned = (unaligned + blockSize - 1) / blockSize * blockSize
        let timestamp = UInt32(truncatingIfNeeded: (DispatchTime.now().uptimeNanoseconds - epoch) * 9 / 100_000)
        for b in 0..<blocks {
            let start = b * aligned
            let len = b == blocks - 1 ? payload.count - start : min(aligned, payload.count - start)
            if len <= 0 { break }
            sendBlock(payload, start, len, b, blocks, fec, timestamp)
        }
        framesSent += 1
    }

    private func sendBlock(_ payload: [UInt8], _ start: Int, _ length: Int, _ blockIndex: Int, _ blocks: Int, _ fecIn: Int, _ timestamp: UInt32) {
        var fec = fecIn
        let blockSize = packetSize + Self.rtpHeader
        let dataShards = (length + blockSize - 1) / blockSize
        var parity = (dataShards * fec + 99) / 100
        if parity < minParity && fec != 0 {
            parity = minParity
            fec = 100 * parity / dataShards
        }
        if dataShards + parity > 255 { parity = 255 - dataShards }
        let total = dataShards + parity
        if shards.count < total * blockSize { shards = [UInt8](repeating: 0, count: total * blockSize) }
        let multiFecBlocks = UInt8((blockIndex << 4) | ((blocks - 1) << 6))
        shards.withUnsafeMutableBufferPointer { sb in
            let s = sb.baseAddress!
            memset(s, 0, total * blockSize)
            _ = payload.withUnsafeBufferPointer { memcpy(s, $0.baseAddress! + start, length) }
            for x in 0..<dataShards {
                let h = s + x * blockSize
                h.le32(16, (lowSeq &+ UInt32(x)) << 8)
                h.le32(20, frameIndex)
                var flags: UInt8 = 0x1 // picture data
                if x == 0 { flags |= 0x4 } // start of frame
                if x == dataShards - 1 { flags |= 0x2 } // end of frame
                h[24] = flags
                h[26] = 0x10
                h[27] = multiFecBlocks
            }
            if fec != 0 && parity > 0 {
                if PxrHostFecEncode(s, Int32(dataShards), Int32(parity), Int32(blockSize)) != 0 { plog("host: FEC encode failed") }
            }
            for x in 0..<total {
                let h = s + x * blockSize
                h.le32(28, UInt32(x << 12 | dataShards << 22 | fec << 4))
                h[0] = 0x90
                h[1] = 0
                h.be16(2, UInt16(truncatingIfNeeded: lowSeq &+ UInt32(x)))
                h.be32(4, timestamp)
                h[27] = multiFecBlocks
                h.le32(20, frameIndex)
                if udp.send(h, blockSize) {
                    packetsSent += 1
                    bytesSent += blockSize
                }
            }
        }
        lowSeq &+= UInt32(total)
    }

    func close() { udp.close() }
}

/// The host's control stream (Sunshine's control_server_t, via Pocket XR for Windows' HostControl, GPLv3): an ENet
/// server on the control port. Every message is AES-GCM with the launch's key (CONTROL_V2: a 12-byte nonce of the
/// sequence number, then 'C','C' from the client or 'H','C' from the host). Handled: key frame requests, loss stats and
/// invalidation (as key frame requests) and input. The ENet calls all run on this class's own thread.
final class HostControl: @unchecked Sendable {
    static let typeIdr: UInt16 = 0x0302, typeInvalidate: UInt16 = 0x0301, typeLossStats: UInt16 = 0x0201,
               typeInput: UInt16 = 0x0206, typeTermination: UInt16 = 0x0109

    private let host: UnsafeMutableRawPointer
    private let key: SymmetricKey
    private var stopping = false
    private var peer: UnsafeMutableRawPointer?
    private var seq: UInt32 = 0
    var keyFrameWanted: (() -> Void)?
    var input: ((UnsafeRawBufferPointer) -> Void)?
    var gone: (() -> Void)?
    private(set) var connected = false
    private var inputs = 0
    private var pendingTermination = false
    private let done = DispatchSemaphore(value: 0)

    init?(port: Int, key: [UInt8]) {
        guard let h = PxrHostEnetStart(Int32(port), 4) else {
            plog("host: the control port \(port) could not be opened")
            return nil
        }
        host = h
        self.key = SymmetricKey(data: key)
        let t = Thread { [weak self] in self?.run() }
        t.name = "host-control"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func run() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while !stopping {
            var p: UnsafeMutableRawPointer?
            var data: UInt32 = 0
            var len: Int32 = 0
            let kind = buf.withUnsafeMutableBufferPointer { PxrHostEnetService(host, 50, &p, &data, $0.baseAddress, Int32($0.count), &len) }
            switch kind {
            case 1:
                peer = p
                connected = true
                plog("host: control stream connected")
            case 2:
                plog("host: control stream disconnected")
                connected = false
                peer = nil
                gone?()
            case 3:
                received(Array(buf[0..<min(Int(len), buf.count)]))
            default:
                break
            }
            if pendingTermination, peer != nil {
                pendingTermination = false
                sendNow(Self.typeTermination, [0x80, 0x03, 0x00, 0x23]) // closed by the server, gracefully
            }
        }
        PxrHostEnetStop(host)
        done.signal()
    }

    private func received(_ m: [UInt8]) {
        guard m.count >= 8 + 16 + 4, m[0] == 0x01, m[1] == 0x00 else { return }
        let length = Int(m[2]) | Int(m[3]) << 8
        let s = UInt32(m[4]) | UInt32(m[5]) << 8 | UInt32(m[6]) << 16 | UInt32(m[7]) << 24
        let plainLen = length - 4 - 16
        guard plainLen >= 4, 4 + length <= m.count else { return }
        var nonce = [UInt8](repeating: 0, count: 12)
        for i in 0..<4 { nonce[i] = UInt8((s >> (8 * UInt32(i))) & 0xFF) }
        nonce[10] = UInt8(ascii: "C")
        nonce[11] = UInt8(ascii: "C")
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: m[24..<(24 + plainLen)], tag: m[8..<24])
            plain = try AES.GCM.open(box, using: key)
        } catch {
            plog("host: a control message did not decrypt")
            return
        }
        let type = UInt16(plain[plain.startIndex]) | UInt16(plain[plain.startIndex + 1]) << 8
        switch type {
        case Self.typeIdr, Self.typeInvalidate:
            plog(String(format: "host: the phone asked for a key frame (0x%04x)", type))
            keyFrameWanted?()
        case Self.typeInput:
            if inputs == 0 { plog("host: first input from the phone") }
            inputs += 1
            plain.dropFirst(4).withUnsafeBytes { input?($0) }
        default:
            break
        }
    }

    /// Tells the phone the stream has ended (sent from the control thread).
    func terminate() { pendingTermination = true }

    private func sendNow(_ type: UInt16, _ payload: [UInt8]) {
        guard let peer else { return }
        var plain = [UInt8](repeating: 0, count: 4 + payload.count)
        plain[0] = UInt8(type & 0xFF); plain[1] = UInt8(type >> 8)
        plain[2] = UInt8(payload.count & 0xFF); plain[3] = UInt8(payload.count >> 8)
        plain.replaceSubrange(4..., with: payload)
        let s = seq
        seq &+= 1
        var nonce = [UInt8](repeating: 0, count: 12)
        for i in 0..<4 { nonce[i] = UInt8((s >> (8 * UInt32(i))) & 0xFF) }
        nonce[10] = UInt8(ascii: "H")
        nonce[11] = UInt8(ascii: "C")
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: nonce)) else { return }
        var msg = [UInt8](repeating: 0, count: 8)
        msg[0] = 0x01
        let length = 4 + 16 + plain.count
        msg[2] = UInt8(length & 0xFF); msg[3] = UInt8(length >> 8)
        for i in 0..<4 { msg[4 + i] = UInt8((s >> (8 * UInt32(i))) & 0xFF) }
        msg += Array(box.tag) + Array(box.ciphertext)
        _ = msg.withUnsafeBufferPointer { PxrHostEnetSend(host, peer, $0.baseAddress, Int32($0.count)) }
    }

    func close() {
        stopping = true
        _ = done.wait(timeout: .now() + 1)
    }
}
