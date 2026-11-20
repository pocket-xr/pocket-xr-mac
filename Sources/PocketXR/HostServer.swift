import Foundation
import CryptoKit
import CoreGraphics
import CoreVideo
import PocketXRCore

/// Pocket XR for Mac as a streaming host that Moonlight's protocol reaches (as Sunshine and Apollo are), so the phone
/// shows this Mac's screens with nothing else installed: one instance per PC screen (up to three), each on its own
/// ports and its own virtual display at the phone window's shape. Ported from Pocket XR for Windows' host (HostServer,
/// HostWeb), itself ported in part from Sunshine and Apollo (GPLv3).
///
/// Ports from the base (HTTP) port P, as Sunshine lays them out: HTTPS P-5, video P+9, control P+10, sound P+11, RTSP
/// P+21. Bases 50989, 51989, 52989: clear of a Sunshine's 47989, 48989, 49989.
final class HostServer: @unchecked Sendable {
    static let desktopAppId = 1
    static let basePorts = [50989, 51989, 52989]

    let index: Int
    let httpPort, httpsPort, videoPort, controlPort, audioPort, rtspPort: Int
    let name: String
    private let shared: HostShared
    private var web: HostListener?, webs: HostListener?, rtsp: HostListener?
    private let mdns = HostMdns()
    private let lock = NSLock()
    private var session: Session?
    private var pairings: [String: Pairing] = [:]

    final class Session {
        var width = 1920, height = 1080, fps = 60
        var key = [UInt8]()
        var keyId = 0
        var pingPayload = ""
        var connectData: UInt32 = 0
        var packetSize = 1392, kbps = 20000, minFec = 2
        var codec = HostEncoder.codecH264
        var audioMs = 5
        var audioEncrypted = true
        var video: HostVideo?
        var control: HostControl?
        var encoder: HostEncoder?
        var capture: HostCapture?
        var audio: HostAudio?
        var input = HostInput()
        var display: CGDirectDisplayID?
        var repeatTimer: DispatchSourceTimer?
        var testTimers: [DispatchSourceTimer] = []
        var stats: DispatchSourceTimer?
        var last: CVPixelBuffer?
        var lastEncode: UInt64 = 0
        var started: UInt64 = 0
        var firstSent = false
        /// The address that launched it: the stream's ports listen to it only.
        var clientIp = ""
        /// Ended (or replaced) while its start was still under way: what the start makes after that is closed again.
        var ended = false
        let encodeQueue = DispatchQueue(label: "host-encode", qos: .userInteractive)
    }

    private final class Pairing {
        var phase = 0
        var aesKey = [UInt8]()
        var clientCert = Data()
        var name = ""
        var serverSecret = [UInt8]()
        var serverChallenge = [UInt8]()
        var clientHash = [UInt8]()
    }

    init(index: Int, shared: HostShared) {
        self.index = index
        self.shared = shared
        let p = Self.basePorts[index - 1]
        httpPort = p; httpsPort = p - 5; videoPort = p + 9; controlPort = p + 10; audioPort = p + 11; rtspPort = p + 21
        name = index == 1 ? shared.name : "\(shared.name) (\(index))"
    }

    func start() {
        web = HostListener(name: "HTTP", port: httpPort, identity: nil) { [weak self] r in self?.answer(r, secure: false) ?? Data() }
        if let id = shared.identity.identity {
            webs = HostListener(name: "HTTPS", port: httpsPort, identity: id) { [weak self] r in self?.answer(r, secure: true) ?? Data() }
        }
        rtsp = HostListener(name: "RTSP", port: rtspPort, identity: nil) { [weak self] r in self?.answerRtsp(r) ?? Data() }
        mdns.register(name: name, port: httpPort)
        plog("host \(index): \(name) on \(httpPort) (HTTPS \(httpsPort), RTSP \(rtspPort))")
    }

    func stop() {
        endSession("the host stopped")
        web?.stop(); webs?.stop(); rtsp?.stop()
        mdns.stop()
    }

    var sessionRunning: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }

    // MARK: Web (Apollo's nvhttp.cpp, via Pocket XR for Windows' HostWeb)

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func xml(_ code: Int, _ message: String = "", _ inner: String = "") -> Data {
        let m = message.isEmpty ? "" : " status_message=\"\(esc(message))\""
        return Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><root status_code=\"\(code)\"\(m)>\(inner)</root>".utf8)
    }

    private static func e(_ tag: String, _ value: Any) -> String { "<\(tag)>\(esc("\(value)"))</\(tag)>" }

    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

    private static func unhex(_ s: String) -> [UInt8]? {
        let c = Array(s.utf8)
        guard c.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(c.count / 2)
        var i = 0
        while i < c.count {
            guard let v = UInt8(String(decoding: c[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
            out.append(v)
            i += 2
        }
        return out
    }

    private func answer(_ r: HostRequest, secure: Bool) -> Data {
        let paired = secure && r.clientCert.map { shared.clients.knows($0) } == true
        let path = String(r.path.drop(while: { $0 == "/" }))
        if path == "actions/clipboard" {
            guard paired else { return HostListener.http(401, Data(), type: "text/plain; charset=utf-8") }
            guard sessionRunning else { return HostListener.http(403, Data(), type: "text/plain; charset=utf-8") }
            if r.method == "POST" {
                let text = String(decoding: r.body, as: UTF8.self)
                let ok = DispatchQueue.main.sync { HostClipboard.set(text) }
                plog("host \(index): clipboard from the phone, \(text.count) characters\(ok ? "" : ": not set")")
                return HostListener.http(ok ? 200 : 403, Data(), type: "text/plain; charset=utf-8")
            }
            let text = DispatchQueue.main.sync { HostClipboard.get() }
            return HostListener.http(200, Data(text.utf8), type: "text/plain; charset=utf-8")
        }
        if path != "serverinfo" { plog("host \(index): \(secure ? "HTTPS" : "HTTP") /\(path) from \(r.remote)\(secure ? (paired ? " (paired)" : " (not paired)") : "")") }
        let q = r.query
        let body: Data
        switch path {
        case "serverinfo": body = serverInfo(paired: paired, local: r.local)
        case "pair": body = pair(q, secure: secure, paired: paired)
        case "unpair": body = Self.xml(200)
        case "applist" where paired:
            body = Self.xml(200, "", "<App><IsHdrSupported>0</IsHdrSupported><AppTitle>Desktop</AppTitle><UUID></UUID><ID>\(Self.desktopAppId)</ID></App>")
        case "launch" where paired, "resume" where paired:
            let tag = path == "launch" ? "gamesession" : "resume"
            switch launch(q, local: r.local, remote: r.remote, resume: path == "resume") {
            case .success(let url): body = Self.xml(200, "", Self.e("sessionUrl0", url) + Self.e(tag, 1))
            case .failure(let why): body = Self.xml(503, why.text, Self.e(tag, 0))
            }
        case "cancel" where paired:
            endSession("the phone ended it")
            body = Self.xml(200, "", Self.e("cancel", 1))
        case "applist", "launch", "resume", "cancel":
            body = Self.xml(401, "The client is not authorized. Certificate verification failed.")
        default:
            return HostListener.http(404, Self.xml(404, "Not Found"))
        }
        return HostListener.http(200, body)
    }

    private func serverInfo(paired: Bool, local: String) -> Data {
        var s = ""
        s += Self.e("hostname", name)
        s += Self.e("appversion", "7.1.431.-1")
        s += Self.e("GfeVersion", "3.23.0.74")
        s += Self.e("uniqueid", shared.identity.uniqueId)
        s += Self.e("HttpsPort", httpsPort)
        s += Self.e("ExternalPort", httpPort)
        s += Self.e("MaxLumaPixelsHEVC", shared.hasHevc ? "1869449984" : "0")
        s += Self.e("mac", "00:00:00:00:00:00")
        // Apollo's bits as the PC helper gives a phone: input, clipboard both ways, launch, view.
        s += Self.e("Permission", paired ? (0x07031F00 | 0x4001800) : 0)
        if paired {
            s += Self.e("VirtualDisplayCapable", "true")
            s += Self.e("VirtualDisplayDriverReady", "true")
        }
        s += Self.e("LocalIP", local)
        s += Self.e("ServerCodecModeSupport", 0x1 | (shared.hasHevc ? 0x100 : 0))
        s += Self.e("PairStatus", paired ? 1 : 0)
        let game = paired && sessionRunning ? Self.desktopAppId : 0
        s += Self.e("currentgame", game)
        s += Self.e("currentgameuuid", "")
        s += Self.e("state", game != 0 ? "SUNSHINE_SERVER_BUSY" : "SUNSHINE_SERVER_FREE")
        return Self.xml(200, "", s)
    }

    // MARK: Pairing (Apollo nvhttp.cpp getservercert ... clientpairingsecret)

    private func fail(_ id: String, _ why: String) -> Data {
        lock.lock(); pairings[id] = nil; lock.unlock()
        plog("host \(index): pairing failed: \(why)")
        return Self.xml(400, why, Self.e("paired", 0))
    }

    private func pair(_ q: [String: String], secure: Bool, paired: Bool) -> Data {
        let id = q["uniqueid"] ?? ""
        if q["phrase"] == "pairchallenge" { return Self.xml(200, "", Self.e("paired", secure && paired ? 1 : 0)) }
        if q["phrase"] == "getservercert" {
            let salt = q["salt"] ?? ""
            guard salt.count >= 32, let saltBytes = Self.unhex(String(salt.prefix(32))) else { return fail(id, "Salt too short") }
            guard let pemBytes = Self.unhex(q["clientcert"] ?? ""), let der = Self.derFromPem(pemBytes),
                  SecCertificateCreateWithData(nil, der as CFData) != nil else { return fail(id, "Invalid client certificate") }
            let deviceName = q["devicename"] ?? "Phone"
            plog("host \(index): \(deviceName) (\(id)) asks to pair: waiting for its PIN")
            guard let got = shared.pins.wait(port: httpPort, seconds: 120) else { return fail(id, "No PIN was given") }
            let (pin, given) = got
            let p = Pairing()
            p.phase = 1
            p.aesKey = Array(SHA256.hash(data: saltBytes + Array(pin.utf8))).prefix(16).map { $0 }
            p.clientCert = der
            p.name = given ?? deviceName
            lock.lock(); pairings[id] = p; lock.unlock()
            return Self.xml(200, "", Self.e("paired", 1) + Self.e("plaincert", Self.hex(Array(shared.identity.pem))))
        }
        lock.lock(); let s = pairings[id]; lock.unlock()
        guard let s else { return fail(id, "Out of order pairing call") }
        if let challenge = q["clientchallenge"] {
            guard s.phase == 1, let c = Self.unhex(challenge) else { return fail(id, "Out of order call to clientchallenge") }
            s.phase = 2
            let dec = HostAes.ecb(c, key: s.aesKey, encrypt: false)
            s.serverSecret = Self.random(16)
            let hash = Array(SHA256.hash(data: dec + Array(shared.identity.certSignature) + s.serverSecret))
            s.serverChallenge = Self.random(16)
            let enc = HostAes.ecb(hash + s.serverChallenge, key: s.aesKey, encrypt: true)
            return Self.xml(200, "", Self.e("paired", 1) + Self.e("challengeresponse", Self.hex(enc)))
        }
        if let resp = q["serverchallengeresp"] {
            guard s.phase == 2, let r = Self.unhex(resp) else { return fail(id, "Out of order call to serverchallengeresp") }
            s.phase = 3
            s.clientHash = HostAes.ecb(r, key: s.aesKey, encrypt: false)
            let secret = s.serverSecret + Array(shared.identity.sign(Data(s.serverSecret)))
            return Self.xml(200, "", Self.e("pairingsecret", Self.hex(secret)) + Self.e("paired", 1))
        }
        if let cps = q["clientpairingsecret"] {
            guard s.phase == 3, let all = Self.unhex(cps) else { return fail(id, "Out of order call to clientpairingsecret") }
            guard all.count > 16 else { return fail(id, "Client pairing secret too short") }
            let secret = Array(all[0..<16]), sign = Array(all[16...])
            lock.lock(); pairings[id] = nil; lock.unlock()
            let clientSig = Der.signature(of: s.clientCert).map { Array($0) } ?? []
            let hash = Array(SHA256.hash(data: s.serverChallenge + clientSig + secret))
            let sameHash = hash == Array(s.clientHash.prefix(32))
            var verified = false
            if let cert = SecCertificateCreateWithData(nil, s.clientCert as CFData), let pub = SecCertificateCopyKey(cert) {
                verified = SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA256, Data(secret) as CFData, Data(sign) as CFData, nil)
            }
            guard sameHash, verified else {
                plog("host \(index): pairing refused (same hash \(sameHash), signature \(verified)): a wrong PIN?")
                return Self.xml(200, "", Self.e("paired", 0))
            }
            shared.clients.add(name: s.name, uniqueId: id, der: s.clientCert)
            plog("host \(index): paired with \(s.name) (\(id))")
            return Self.xml(200, "", Self.e("paired", 1))
        }
        return fail(id, "Unknown pairing step")
    }

    private static func random(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b
    }

    /// A PEM certificate's DER (the base64 between the lines).
    private static func derFromPem(_ pem: [UInt8]) -> Data? {
        let text = String(decoding: pem, as: UTF8.self)
        let b64 = text.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
    }

    // MARK: Launch

    struct Refusal: Error { let text: String }

    private func launch(_ q: [String: String], local: String, remote: String, resume: Bool) -> Result<String, Refusal> {
        let mode = (q["mode"] ?? "").split(separator: "x").compactMap { Int($0) }
        guard mode.count == 3, let keyHex = q["rikey"], keyHex.count == 32, let key = Self.unhex(keyHex), let keyId = Int(q["rikeyid"] ?? "") else {
            plog("host \(index): launch refused: no mode, rikey or rikeyid")
            return .failure(Refusal(text: "The launch had no stream settings."))
        }
        // No Screen Recording: refused at once with a clear reason (the phone says it), and one message on the Mac,
        // instead of a stream that never sends a picture and a virtual screen that comes and goes with each retry.
        if !HostPermissions.screenAllowed {
            plog("host \(index): launch refused: Pocket XR is not allowed to record the screen")
            HostPermissions.show(because: "Your phone tried to show this Mac's screen.")
            return .failure(Refusal(text: HostPermissions.refusalText))
        }
        lock.lock()
        // A resume is a new start here too: the phone gave a new key, and a start still under way is ended first.
        if let s = session { stopLocked(s, resume ? "the phone resumed" : "a new launch"); session = nil }
        let s = Session()
        session = s
        s.width = mode[0]; s.height = mode[1]; s.fps = max(1, mode[2])
        s.key = key
        s.keyId = keyId
        s.clientIp = remote
        s.pingPayload = Self.hex(Self.random(8))
        s.connectData = UInt32.random(in: 1..<UInt32(Int32.max))
        lock.unlock()
        plog("host \(index): \(resume ? "resume" : "launch") \(s.width)x\(s.height)@\(s.fps), virtual display asked \(q["virtualdisplay"] ?? "0")")
        // The virtual screen made ready now, while RTSP goes on (bringing one out can take seconds).
        let i = index, m = HostScreens.Mode.clamped(s.width, s.height, s.fps)
        DispatchQueue.global(qos: .userInitiated).async { [shared] in _ = shared.screens.prepare(i, m) }
        return .success("rtsp://\(local):\(rtspPort)")
    }

    func endSession(_ why: String) {
        lock.lock()
        if let s = session { stopLocked(s, why); session = nil }
        lock.unlock()
    }

    private func stopLocked(_ s: Session, _ why: String) {
        plog("host \(index): session ended (\(why))")
        s.ended = true
        s.stats?.cancel()
        s.repeatTimer?.cancel()
        s.testTimers.forEach { $0.cancel() }
        s.control?.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        s.capture?.stop()
        s.encodeQueue.sync { s.encoder?.close() }
        s.audio?.close()
        s.video?.close()
        s.control?.close()
        s.capture = nil; s.encoder = nil; s.audio = nil; s.video = nil; s.control = nil
        if s.display != nil {
            let i = index
            DispatchQueue.global().async { [shared] in shared.screens.idle(i) }
        }
    }

    // MARK: RTSP (Sunshine's rtsp.cpp)

    private func answerRtsp(_ r: HostRequest) -> Data {
        let cseq = r.headers["cseq"] ?? "0"
        lock.lock(); let s = session; lock.unlock()
        plog("host \(index): RTSP \(r.method) \(r.target)")
        var options: [(String, String)] = []
        var payload = ""
        var status = 200
        switch r.method {
        case "OPTIONS":
            break
        case "DESCRIBE":
            // Control encryption V2 and sound encryption offered (1 | 4), as Sunshine; video unencrypted. HEVC offered when
            // this Mac encodes it (the phone takes HEVC, then H.264).
            payload = (shared.hasHevc ? "sprop-parameter-sets=AAAAAU\n" : "") +
                "a=x-ss-general.featureFlags:0\na=x-ss-general.encryptionSupported:5\na=x-ss-general.encryptionRequested:1\n"
        case "SETUP":
            guard let s else { status = 404; break }
            let type = r.target.range(of: "streamid=")
                .map { String(r.target[$0.upperBound...].prefix { $0.isLetter || $0.isNumber }) } ?? ""
            let port = ["audio": audioPort, "video": videoPort, "control": controlPort][type] ?? 0
            guard port != 0 else { status = 404; break }
            options.append(("Session", "DEADBEEFCAFE;timeout = 90"))
            options.append(("Transport", "server_port=\(port)"))
            if type == "control" { options.append(("X-SS-Connect-Data", "\(s.connectData)")) }
            else { options.append(("X-SS-Ping-Payload", s.pingPayload)) }
        case "ANNOUNCE":
            guard let s else { status = 404; break }
            readAnnounce(s, String(decoding: r.body, as: UTF8.self))
        case "PLAY":
            guard let s else { status = 404; break }
            begin(s)
        default:
            status = 404
        }
        var text = "RTSP/1.0 \(status) \(status == 200 ? "OK" : "NOT FOUND")\r\nCSeq: \(cseq)\r\n"
        for (k, v) in options { text += "\(k): \(v)\r\n" }
        if !payload.isEmpty { text += "Content-length: \(payload.utf8.count)\r\n" }
        text += "\r\n" + payload
        return Data(text.utf8)
    }

    private static func sdp(_ body: String, _ key: String) -> Int? {
        guard let r = body.range(of: key + ":") else { return nil }
        let rest = body[r.upperBound...].drop { $0 == " " }
        let digits = rest.prefix { $0 == "-" || $0.isNumber }
        return Int(digits)
    }

    private func readAnnounce(_ s: Session, _ body: String) {
        s.width = Self.sdp(body, "x-nv-video[0].clientViewportWd") ?? s.width
        s.height = Self.sdp(body, "x-nv-video[0].clientViewportHt") ?? s.height
        s.fps = Self.sdp(body, "x-nv-video[0].maxFPS") ?? s.fps
        if s.fps > shared.maxFps {
            plog("host \(index): \(s.fps) frames a second asked; \(shared.maxFps) here (this Mac's encoder)")
            s.fps = shared.maxFps
        }
        s.packetSize = Self.sdp(body, "x-nv-video[0].packetSize") ?? s.packetSize
        s.kbps = Self.sdp(body, "x-nv-vqos[0].bw.maximumBitrateKbps") ?? s.kbps
        s.minFec = Self.sdp(body, "x-nv-vqos[0].fec.minRequiredFecPackets") ?? s.minFec
        let enc = Self.sdp(body, "x-ss-general.encryptionEnabled") ?? 0
        s.audioMs = Self.sdp(body, "x-nv-aqos.packetDuration") ?? 5
        s.audioEncrypted = enc & 4 != 0 || (Self.sdp(body, "x-nv-general.featureFlags") ?? 0) & 0x20 != 0
        let format = Self.sdp(body, "x-nv-vqos[0].bitStreamFormat") ?? 0
        s.codec = format == 1 && shared.hasHevc ? HostEncoder.codecHevc : HostEncoder.codecH264
        plog("host \(index): ANNOUNCE \(s.width)x\(s.height)@\(s.fps), \(s.kbps / 1000) Mbps, packets \(s.packetSize), FEC minimum \(s.minFec), encryption \(enc), bitstream \(format)")
    }

    private func begin(_ s: Session) {
        guard s.encoder == nil else { return }
        s.started = DispatchTime.now().uptimeNanoseconds
        guard let video = HostVideo(port: videoPort, packetSize: s.packetSize, fecPercent: 20, minParity: s.minFec, clientIp: s.clientIp),
              let control = HostControl(port: controlPort, key: s.key) else {
            plog("host \(index): the stream's ports could not be opened")
            return
        }
        s.video = video
        s.control = control
        control.gone = { [weak self] in DispatchQueue.global().async { self?.endSession("the phone went") } }
        // The rest after PLAY is answered: the screen may take seconds to come out, and the phone gives up on a slow PLAY.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.finishBegin(s) }
    }

    private func finishBegin(_ s: Session) {
        guard let video = s.video, let control = s.control else { return }
        // The phone's window: the virtual display at its shape; the main display (scaled) if none could be made.
        let mode = HostScreens.Mode.clamped(s.width, s.height, s.fps)
        let display = shared.screens.stream(index, mode)
        lock.lock()
        let ended = s.ended
        if !ended { s.display = display }
        lock.unlock()
        if ended {
            plog("host \(index): a start ended before its screen was ready")
            if display != nil { shared.screens.idle(index) }
            return
        }
        let capDisplay = display ?? CGMainDisplayID()
        s.input.area = CGDisplayBounds(capDisplay)
        let input = s.input
        control.input = { input.handle($0) }
        guard let encoder = HostEncoder(width: s.width, height: s.height, fps: s.fps, kbps: s.kbps, codec: s.codec, onFrame: { [weak s] frame, key, taken in
            guard let s, let v = s.video, v.hasClient else { return }
            if !s.firstSent {
                s.firstSent = true
                plog("host: first frame sent (\(frame.count) bytes, key \(key)), \((DispatchTime.now().uptimeNanoseconds - s.started) / 1_000_000) ms after PLAY")
            }
            let latency = Int((DispatchTime.now().uptimeNanoseconds - taken) / 100_000)
            v.send(frame, idr: key, latency: latency)
        }) else {
            plog("host \(index): no hardware encoder took the stream")
            return
        }
        s.encoder = encoder
        control.keyFrameWanted = { [weak encoder] in encoder?.requestIdr() }
        video.firstClient = { [weak encoder] in
            encoder?.requestIdr()
            input.centre()
        }
        let i = index
        let audio = HostAudio(port: audioPort, durationMs: s.audioMs, encrypt: s.audioEncrypted, key: s.key, keyId: s.keyId, clientIp: s.clientIp)
        s.audio = audio
        let capture = HostCapture()
        lock.lock()
        if s.ended {
            lock.unlock()
            encoder.close()
            audio?.close()
            return
        }
        s.capture = capture
        lock.unlock()
        capture.onVideo = { [weak s] pb, taken in
            guard let s else { return }
            s.encodeQueue.async {
                s.last = pb
                s.lastEncode = DispatchTime.now().uptimeNanoseconds
                s.encoder?.encode(pb, taken: taken)
            }
        }
        capture.onAudio = { [weak audio] sb in audio?.captured(sb) }
        let (w, h, fps) = (s.width, s.height, s.fps)
        Task {
            if let why = await capture.start(display: capDisplay, width: w, height: h, fps: fps, sound: true) {
                plog("host \(i): no picture: \(why) (Pocket XR needs Screen Recording: System Settings, Privacy & Security)")
                if ProcessInfo.processInfo.environment["PXR_HOST_TEST"] == "1" { HostTestSource.start(s, capture: capture, audio: audio) }
            } else {
                plog("host \(i): capturing display \(capDisplay) at \(w)x\(h) up to \(fps)/s, with sound")
            }
        }
        // A still screen: its last picture again about 10 times a second, so the phone never waits long on a frame,
        // and a real change does not wait behind repeats in the encoder.
        let interval: UInt64 = HostEncoder.oldSpeed ? 1_000_000_000 / UInt64(max(1, s.fps)) * 3 / 2 : 100_000_000
        let t = DispatchSource.makeTimerSource(queue: s.encodeQueue)
        let tick = HostEncoder.oldSpeed ? max(1, 1000 / max(1, s.fps)) : 25
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(tick), leeway: .milliseconds(1))
        t.setEventHandler { [weak s] in
            guard let s, let pb = s.last else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - s.lastEncode >= interval {
                s.lastEncode = now
                s.encoder?.encode(pb, taken: now)
            }
        }
        t.resume()
        s.repeatTimer = t
        var last = (frames: 0, bytes: 0, outs: 0, keys: 0, outBytes: 0, ms: 0.0)
        let st = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        st.schedule(deadline: .now() + 10, repeating: 10)
        st.setEventHandler { [weak s] in
            guard let s, let v = s.video, let e = s.encoder else { return }
            let outs = e.outputs - last.outs
            plog(String(format: "host %ld: %.1f frames/s sent, %.1f Mbps, %ld key, %ld KB each, encode %.1f ms (max %.1f), %ld captured, %ld dropped as newer came, %ld input events, %ld sound packets, control %@",
                        i, Double(v.framesSent - last.frames) / 10, Double(v.bytesSent - last.bytes) * 8 / 10 / 1e6, e.keys - last.keys,
                        outs > 0 ? (e.outBytes - last.outBytes) / outs / 1024 : 0, outs > 0 ? (e.encodeMsSum - last.ms) / Double(outs) : 0,
                        e.encodeMsMax, s.capture?.captured ?? 0, e.dropped, s.input.sent, s.audio?.packetsSent ?? 0,
                        s.control?.connected == true ? "connected" : "not connected"))
            e.encodeMsMax = 0
            last = (v.framesSent, v.bytesSent, e.outputs, e.keys, e.outBytes, e.encodeMsSum)
        }
        st.resume()
        s.stats = st
    }
}

/// What the host's instances share: this Mac's name, identity, paired phones, virtual screens, codecs and the PINs.
final class HostShared: @unchecked Sendable {
    let name: String
    let identity: HostIdentity
    let clients = HostClients()
    let screens = HostScreens()
    let pins = HostPins()
    let hasHevc: Bool
    let maxFps: Int

    init?(name: String) {
        guard let id = HostIdentity.load() else { return nil }
        self.name = name
        identity = id
        let env = ProcessInfo.processInfo.environment
        // HEVC only where it can have low-latency rate control (not on the Intel Air: there H.264 with it was 13 ms a
        // frame and HEVC without it 18-22 ms). PXR_HOST_CODEC=hevc or h264 for tests.
        hasHevc = env["PXR_HOST_CODEC"] == "hevc" || HostEncoder.oldSpeed ? HostEncoder.available(HostEncoder.codecHevc)
            : env["PXR_HOST_CODEC"] != "h264" && HostEncoder.available(HostEncoder.codecHevc, lowLatency: true)
        // No cap by default: on the Intel Air (test picture, 1784x976, H.264 with low-latency rate control, one frame in
        // the encoder at a time) 120 asked gave 9.5 ms a frame and ~88 frames/s sent, 60 gave 13.0 ms at 60 (20 Nov
        // 2026). PXR_HOST_MAX_FPS=60 caps it, for comparing by feel.
        maxFps = Int(env["PXR_HOST_MAX_FPS"] ?? "") ?? 1000
    }
}

/// The PIN a pairing phone shows, given to the host: by the phone itself through the PC helper's words (apollo-pin,
/// HostHelper), from a file (PocketXR --host-pin 1234), or typed on this Mac when asked.
final class HostPins: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Set<Int> = []
    private var given: [Int: (pin: String, name: String?)] = [:]
    /// A PIN that came before its pairing did (the phone sends it over the helper words just before its /pair, seen
    /// 12:22:45: 30 ms early): kept for 30 s for that port.
    private var early: [Int: (pin: String, name: String?, at: Date)] = [:]
    static var file: URL { HostIdentity.folder.appendingPathComponent("pin.txt") }
    /// Asks this Mac's user for the PIN (after a few seconds with none from the phone); called off the main thread.
    var ask: ((Int) -> String?)?
    /// Closes that question (the PIN came another way, or the pairing ended).
    var dismiss: (() -> Void)?
    /// The PC helper's words are answered here, so the phone gives its PIN itself (after its user's Allow click).
    var phoneGivesPin: (() -> Bool)?

    /// The PIN for the host on [port], from the PC helper words; false when no phone waits there.
    func submit(_ pin: String, name: String?, port: Int) -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard HostServer.basePorts.contains(port) else { return false }
        if waiting.contains(port) { given[port] = (pin, name) } else { early[port] = (pin, name, Date()) }
        return true
    }

    func isWaiting(_ port: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return waiting.contains(port) }

    func wait(port: Int, seconds: Double) -> (String, String?)? {
        lock.lock()
        waiting.insert(port)
        given[port] = nil
        if let e = early[port], Date().timeIntervalSince(e.at) < 30 { given[port] = (e.pin, e.name) }
        early[port] = nil
        lock.unlock()
        var asked = false
        defer {
            lock.lock(); waiting.remove(port); given[port] = nil; lock.unlock()
            if asked { dismiss?() }
        }
        // The phone gives the PIN over the PC helper's words, after this Mac's user allows it (seen: 4.8 s): the PIN
        // box comes only if none came in 25 s; at once (3 s) when those words are not answered here.
        let askAfter: Double = phoneGivesPin?() == true ? 25 : 3
        try? FileManager.default.removeItem(at: Self.file)
        plog("host: a phone wants to pair on \(port): waiting for its PIN (from the phone, or PocketXR --host-pin NNNN) for \(Int(seconds)) s")
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            lock.lock(); let g = given[port]; lock.unlock()
            if let g { return (g.pin, g.name) }
            if let text = try? String(contentsOf: Self.file, encoding: .utf8) {
                try? FileManager.default.removeItem(at: Self.file)
                let pin = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if pin.count == 4, pin.allSatisfy(\.isNumber) { return (pin, nil) }
            }
            // No PIN from the phone after 3 s (no PC helper words reached this Mac): this Mac's user is asked.
            if !asked, Date() > end.addingTimeInterval(-seconds + askAfter), let ask {
                asked = true
                let q = DispatchQueue.global()
                q.async { [weak self] in
                    guard let self, let pin = ask(port) else { return }
                    _ = self.submit(pin, name: nil, port: port)
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}

/// Tests only (PXR_HOST_TEST=1, when capture is refused, as it is to a program started over ssh): a moving test
/// picture at the stream's rate and a quiet tone, so the rest of the stream can be measured.
enum HostTestSource {
    static func start(_ s: HostServer.Session, capture: HostCapture, audio: HostAudio?) {
        let w = s.width, h = s.height
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let pool else { return }
        var frame = 0
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        let ns = 1_000_000_000 / max(1, s.fps)
        t.schedule(deadline: .now(), repeating: .nanoseconds(ns))
        t.setEventHandler {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let bar = (frame * 8) % w
            for row in 0..<h {
                let line = y + row * yStride
                for x in 0..<w { line[x] = abs(x - bar) < 40 ? 235 : UInt8(16 + (x * 200 / w)) }
            }
            let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
            CVPixelBufferUnlockBaseAddress(pb, [])
            frame += 1
            capture.onVideo?(pb, DispatchTime.now().uptimeNanoseconds)
        }
        t.resume()
        s.testTimers.append(t)
        if let audio {
            let a = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
            a.schedule(deadline: .now(), repeating: .milliseconds(5))
            a.setEventHandler { audio.testTone(ms: 5) }
            a.resume()
            s.testTimers.append(a)
        }
        plog("host: test picture \(w)x\(h) and tone instead of capture (PXR_HOST_TEST)")
    }
}
