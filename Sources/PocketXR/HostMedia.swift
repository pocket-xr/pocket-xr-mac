import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AudioToolbox
import CommonCrypto
import CHostNet
import PocketXRCore

/// The host's picture and sound from one display: ScreenCaptureKit, the pointer drawn in (the phone shows the Mac's
/// pointer only from the picture), sound from everything the Mac plays (not Pocket XR's own), 48 kHz stereo.
final class HostCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "host-capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "host-capture-audio", qos: .userInteractive)
    var onVideo: ((CVPixelBuffer, UInt64) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    private(set) var captured = 0
    private(set) var error = ""

    /// Starts capturing [display] at [width]x[height] (its own size: no scaling) up to [fps]. Nil when it runs, else why not.
    func start(display: CGDirectDisplayID, width: Int, height: Int, fps: Int, sound: Bool) async -> String? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let d = content.displays.first(where: { $0.displayID == display }) ?? content.displays.first else {
                return "no display to capture"
            }
            if d.displayID != display { plog("host: display \(display) not offered for capture: the main one instead") }
            let filter = SCContentFilter(display: d, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = width
            cfg.height = height
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.showsCursor = true
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            cfg.queueDepth = 5
            if sound {
                cfg.capturesAudio = true
                cfg.sampleRate = 48000
                cfg.channelCount = 2
                cfg.excludesCurrentProcessAudio = true
            }
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if sound { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
            try await s.startCapture()
            stream = s
            return nil
        } catch {
            return "\(error.localizedDescription)"
        }
    }

    func stop() {
        let s = stream
        stream = nil
        s?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { onAudio?(sb); return }
        guard type == .screen else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return // idle or blank: nothing new
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        captured += 1
        onVideo?(pb, DispatchTime.now().uptimeNanoseconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.error = error.localizedDescription
        plog("host: capture stopped: \(error.localizedDescription)")
    }
}

/// The host's video encoder: VideoToolbox, hardware, H.264 or HEVC, real time with no frame reordering, peak-limited
/// variable bitrate (constant bitrate filled every frame and lagged on the phone, 20 Nov 2026), a key frame only when
/// asked. Frames out as Annex B with the parameter sets in front of every key frame (the phone finds key frames by
/// reading the bitstream).
final class HostEncoder: @unchecked Sendable {
    static let codecH264 = 0, codecHevc = 1
    private var session: VTCompressionSession?
    private let onFrame: ([UInt8], Bool, UInt64) -> Void
    private var idrWanted = true
    private let lock = NSLock()
    let codec: Int
    let width: Int, height: Int, fps: Int, kbps: Int
    private(set) var outputs = 0, keys = 0, outBytes = 0
    private(set) var encodeMsSum = 0.0
    var encodeMsMax = 0.0
    private(set) var lowLatency = false
    private var frameNo: Int64 = 0
    /// One frame in the encoder at a time: one that comes while it is busy waits, and a newer one replaces it (the
    /// older is dropped). So a slow encoder (the Intel Air: 13-22 ms a frame) shows the newest picture, never a queue.
    private var busy = false
    private var pending: (CVPixelBuffer, UInt64)?
    private(set) var dropped = 0

    /// Whether this Mac encodes [codec] in hardware, with low-latency rate control if [lowLatency] (a small session
    /// made and thrown away).
    static func available(_ codec: Int, lowLatency: Bool = false) -> Bool {
        var s: VTCompressionSession?
        var specs: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { specs[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        let spec = specs as CFDictionary
        let r = VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: codec == codecHevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                           encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                           outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if let s { VTCompressionSessionInvalidate(s) }
        return r == noErr && s != nil
    }

    init?(width: Int, height: Int, fps: Int, kbps: Int, codec: Int, onFrame: @escaping ([UInt8], Bool, UInt64) -> Void) {
        self.width = width; self.height = height; self.fps = fps; self.kbps = kbps; self.codec = codec
        self.onFrame = onFrame
        let type = codec == Self.codecHevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var s: VTCompressionSession?
        for low in [true, false] {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if low { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            let r = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                               encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                               compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            if r == noErr, s != nil { lowLatency = low; break }
            plog("host: encoder \(low ? "with" : "without") low-latency rate control refused (\(r))")
        }
        guard let s else { return nil }
        session = s
        func set(_ k: CFString, _ v: Any) {
            let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if r != noErr { plog("host: encoder setting \(k) refused (\(r))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel, codec == Self.codecHevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Int32.max))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 100_000)
        set(kVTCompressionPropertyKey_AverageBitRate, kbps * 1000 * 3 / 4)
        set(kVTCompressionPropertyKey_DataRateLimits, [kbps * 1000 / 8, 1] as CFArray)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if codec == Self.codecH264 { set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC) }
        if ProcessInfo.processInfo.environment["PXR_HOST_ENC_FAST"] == "1" {
            set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
        plog("host: encoder \(codec == Self.codecHevc ? "HEVC" : "H.264") \(width)x\(height)@\(fps), up to \(kbps / 1000) Mbps (VBR, mean 3/4), low-latency rate control \(lowLatency ? "on" : "off")")
    }

    /// The next frame is a key frame (the phone asked, or lost one).
    func requestIdr() { lock.lock(); idrWanted = true; lock.unlock() }

    /// Tests only (PXR_HOST_OLD_SPEED=1): the first build's behaviour, to measure against.
    static let oldSpeed = ProcessInfo.processInfo.environment["PXR_HOST_OLD_SPEED"] == "1"

    func encode(_ pb: CVPixelBuffer, taken: UInt64) {
        if Self.oldSpeed { submit(pb, taken: taken); return }
        lock.lock()
        if busy {
            if pending != nil { dropped += 1 }
            pending = (pb, taken)
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        submit(pb, taken: taken)
    }

    /// The encoder is free again: the waiting picture, if any, goes in.
    private func finished() {
        if Self.oldSpeed { return }
        lock.lock()
        if let (pb, taken) = pending {
            pending = nil
            lock.unlock()
            submit(pb, taken: taken)
        } else {
            busy = false
            lock.unlock()
        }
    }

    private func submit(_ pb: CVPixelBuffer, taken: UInt64) {
        guard let s = session else { lock.lock(); busy = false; lock.unlock(); return }
        lock.lock()
        let idr = idrWanted
        idrWanted = false
        frameNo += 1
        let n = frameNo
        lock.unlock()
        let props = idr ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = DispatchTime.now().uptimeNanoseconds
        let pts = CMTime(value: n, timescale: CMTimeScale(max(1, fps)))
        let r = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self else { return }
            defer { self.finished() }
            guard status == noErr, let sb else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            self.encodeMsSum += ms
            self.encodeMsMax = max(self.encodeMsMax, ms)
            let key = Self.isKey(sb)
            guard let bytes = Self.annexB(sb, key: key, hevc: self.codec == Self.codecHevc) else { return }
            self.outputs += 1
            if key { self.keys += 1 }
            self.outBytes += bytes.count
            self.onFrame(bytes, key, taken)
        }
        if r != noErr { finished() }
    }

    static func isKey(_ sb: CMSampleBuffer) -> Bool {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = atts.first else { return true }
        return !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// The frame as Annex B (start codes), the parameter sets first on a key frame.
    static func annexB(_ sb: CMSampleBuffer, key: Bool, hevc: Bool) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data) == noErr else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(length + 256)
        var headerLength: Int32 = 4
        if key, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            if hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            }
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                let r = hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if r == noErr, let p {
                    out += [0, 0, 0, 1]
                    out += UnsafeBufferPointer(start: p, count: n)
                }
            }
        }
        let hl = Int(headerLength)
        var at = 0
        while at + hl <= data.count {
            var n = 0
            for i in 0..<hl { n = n << 8 | Int(data[at + i]) }
            at += hl
            guard n > 0, at + n <= data.count else { break }
            out += [0, 0, 0, 1]
            out += data[at..<(at + n)]
            at += n
        }
        return out
    }

    func close() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }
}

/// AES-128 with CommonCrypto: ECB without padding (pairing) and CBC with PKCS7 (sound).
enum HostAes {
    static func run(_ op: Int, _ data: [UInt8], key: [UInt8], iv: [UInt8]?, options: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let r: CCCryptorStatus
        if let iv {
            r = CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(options), key, key.count, iv, data, data.count, &out, out.count, &moved)
        } else {
            r = CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(options), key, key.count, nil, data, data.count, &out, out.count, &moved)
        }
        return r == CCCryptorStatus(kCCSuccess) ? Array(out.prefix(moved)) : []
    }

    static func ecb(_ data: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        var padded = data
        while padded.count % 16 != 0 { padded.append(0) }
        return run(encrypt ? kCCEncrypt : kCCDecrypt, padded, key: key, iv: nil, options: kCCOptionECBMode)
    }

    static func cbc(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        run(kCCEncrypt, data, key: key, iv: iv, options: kCCOptionPKCS7Padding)
    }
}

/// The host's sound (Sunshine's audioBroadcastThread, via Pocket XR for Windows' HostAudio, GPLv3): what the Mac plays,
/// 48 kHz stereo, Opus (macOS's own encoder) at 192 kbps in packets of the client's duration (5 ms), each RTP payload
/// type 97, AES-CBC encrypted when the client asks (key: the launch's key; IV: the big-endian key id plus the
/// sequence number); after every four packets two Reed-Solomon parity packets (type 127, GameStream's own matrix).
final class HostAudio: @unchecked Sendable {
    private let udp: HostUdp
    private let frameSamples: Int
    private let durationMs: Int
    private let encrypt: Bool
    private let key: [UInt8]
    private let keyId: UInt32
    private var converter: AudioConverterRef?
    private var pending = [Float]()
    private var seq: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var shards = [[UInt8]](repeating: [], count: 4)
    private var shardLen = 0
    private var baseSeq: UInt16 = 0
    private var baseTimestamp: UInt32 = 0
    private(set) var packetsSent = 0
    private let input = UnsafeMutablePointer<Float>.allocate(capacity: 48 * 20 * 2)
    private var given = false
    private let outBuf = UnsafeMutableRawPointer.allocate(byteCount: 4000, alignment: 16)
    private var logged = false

    init?(port: Int, durationMs: Int, encrypt: Bool, key: [UInt8], keyId: Int, clientIp: String? = nil) {
        guard let u = HostUdp(port: port, name: "sound", allowedIp: clientIp) else { return nil }
        udp = u
        self.durationMs = [5, 10, 20].contains(durationMs) ? durationMs : 5
        frameSamples = 48 * self.durationMs
        self.encrypt = encrypt
        self.key = key
        self.keyId = UInt32(truncatingIfNeeded: keyId)
        var out = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                              mFramesPerPacket: UInt32(frameSamples), mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var inp = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                              mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let r = AudioConverterNew(&inp, &out, &converter)
        if r != noErr || converter == nil {
            plog("host: no Opus encoder for \(self.durationMs) ms packets (\(r)): no sound")
            converter = nil
        } else {
            var br: UInt32 = 192_000
            AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate, 4, &br)
            // Constant bitrate: every packet the same size, which the client's sound error correction needs (with
            // varying sizes it turns it off: "Audio block size mismatch").
            if ProcessInfo.processInfo.environment["PXR_HOST_OPUS_CBR"] != "0" {
                var mode = UInt32(kAudioCodecBitRateControlMode_Constant)
                let m = AudioConverterSetProperty(converter!, kAudioCodecPropertyBitRateControlMode, 4, &mode)
                if m != noErr { plog("host: sound: constant bitrate refused (\(m))") }
            }
            plog("host: sound: Opus 192 kbps in \(self.durationMs) ms packets, \(encrypt ? "encrypted" : "not encrypted")")
        }
    }

    /// Captured sound (ScreenCaptureKit: 48 kHz, two channels, float, usually one buffer per channel).
    func captured(_ sb: CMSampleBuffer) {
        guard converter != nil, udp.hasClient, let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return }
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { ablRaw.deallocate() }
        let abl = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: size,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &block) == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat, asbd.mBitsPerChannel == 32 else {
            if !logged { logged = true; plog("host: sound format not float 32 (\(asbd.mFormatFlags), \(asbd.mBitsPerChannel) bits): no sound") }
            return
        }
        let frames = CMSampleBufferGetNumSamples(sb)
        if buffers.count >= 2 {
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { pending.append(l[i]); pending.append(r[i]) }
        } else if let d = buffers.first?.mData {
            let ch = Int(max(1, asbd.mChannelsPerFrame))
            let p = d.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { pending.append(p[i * ch]); pending.append(p[i * ch + (ch > 1 ? 1 : 0)]) }
        }
        flush()
    }

    /// Tests (PXR_HOST_TEST=1, no capture over ssh): a quiet 440 Hz tone, [ms] of it.
    private var tonePhase = 0.0
    func testTone(ms: Int) {
        guard converter != nil, udp.hasClient else { return }
        for _ in 0..<(48 * ms) {
            let v = Float(sin(tonePhase) * 0.1)
            tonePhase += 2 * .pi * 440 / 48000
            pending.append(v); pending.append(v)
        }
        flush()
    }

    private func flush() {
        let n = frameSamples * 2
        while pending.count >= n {
            pending.withUnsafeBufferPointer { input.update(from: $0.baseAddress!, count: n) }
            pending.removeFirst(n)
            sendFrame()
        }
    }

    private func sendFrame() {
        guard let conv = converter else { return }
        given = false
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 4000, mData: outBuf))
        var packets: UInt32 = 1
        var desc = AudioStreamPacketDescription()
        let r = AudioConverterFillComplexBuffer(conv, { _, ioN, ioData, _, user in
            let me = Unmanaged<HostAudio>.fromOpaque(user!).takeUnretainedValue()
            if me.given { ioN.pointee = 0; return 1 }
            me.given = true
            ioN.pointee = UInt32(me.frameSamples)
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(me.input)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(me.frameSamples * 8)
            ioData.pointee.mBuffers.mNumberChannels = 2
            return 0
        }, Unmanaged.passUnretained(self).toOpaque(), &packets, &abl, &desc)
        guard (r == noErr || r == 1), packets > 0, abl.mBuffers.mDataByteSize > 0 else { return }
        let encoded = [UInt8](UnsafeRawBufferPointer(start: outBuf, count: Int(abl.mBuffers.mDataByteSize)))
        var payload = encoded
        if encrypt {
            var iv = [UInt8](repeating: 0, count: 16)
            let v = keyId &+ UInt32(seq)
            iv[0] = UInt8(v >> 24); iv[1] = UInt8((v >> 16) & 0xFF); iv[2] = UInt8((v >> 8) & 0xFF); iv[3] = UInt8(v & 0xFF)
            payload = HostAes.cbc(encoded, key: key, iv: iv)
        }
        var packet = [UInt8](repeating: 0, count: 12)
        packet[0] = 0x80
        packet[1] = 97
        packet[2] = UInt8(seq >> 8); packet[3] = UInt8(seq & 0xFF)
        for i in 0..<4 { packet[4 + i] = UInt8((timestamp >> (8 * UInt32(3 - i))) & 0xFF) }
        packet += payload
        _ = packet.withUnsafeBytes { udp.send($0.baseAddress!, $0.count) }
        packetsSent += 1
        let slot = Int(seq % 4)
        if slot == 0 {
            baseSeq = seq
            baseTimestamp = timestamp
            shardLen = payload.count
        }
        shards[slot] = payload
        if payload.count != shardLen { shardLen = -1 }
        if slot == 3 && shardLen > 0 { sendParity() }
        seq &+= 1
        timestamp &+= UInt32(durationMs)
    }

    private func sendParity() {
        var all = [UInt8](repeating: 0, count: 6 * shardLen)
        for i in 0..<4 { all.replaceSubrange((i * shardLen)..<((i + 1) * shardLen), with: shards[i]) }
        let r = all.withUnsafeMutableBufferPointer { PxrHostAudioFecEncode($0.baseAddress, Int32(shardLen)) }
        guard r == 0 else { return }
        for x in 0..<2 {
            var packet = [UInt8](repeating: 0, count: 24)
            packet[0] = 0x80
            packet[1] = 127
            let s = seq &+ UInt16(x + 1)
            packet[2] = UInt8(s >> 8); packet[3] = UInt8(s & 0xFF)
            packet[12] = UInt8(x)
            packet[13] = 97
            packet[14] = UInt8(baseSeq >> 8); packet[15] = UInt8(baseSeq & 0xFF)
            for i in 0..<4 { packet[16 + i] = UInt8((baseTimestamp >> (8 * UInt32(3 - i))) & 0xFF) }
            packet += all[((4 + x) * shardLen)..<((5 + x) * shardLen)]
            _ = packet.withUnsafeBytes { udp.send($0.baseAddress!, $0.count) }
        }
    }

    func close() {
        udp.close()
        if let c = converter { AudioConverterDispose(c) }
        converter = nil
    }
}
