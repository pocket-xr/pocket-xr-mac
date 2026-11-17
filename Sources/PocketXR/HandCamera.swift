import AVFoundation
import CoreImage
import PocketXRCore
import QuartzCore
import Vision

// The camera side of hand tracking: finds the glasses' camera among the Mac's video devices, opens it with
// AVFoundation, and runs Apple's Vision hand pose detector on its frames on a queue of its own. Nothing here has
// been tried on a Mac with glasses: XREAL's firmware 16.1.04 and later turns the Aura's camera off for hosts.

/// One frame's hands, as the detector found them.
struct HandCameraFrame {
    /// At most two, in the detector's order.
    let hands: [HandPoints]
    /// When the frame arrived, milliseconds on the Mac's steady clock.
    let timeMs: Double
    /// The picture's width over its height.
    let aspect: Double
}

/// Opens one camera and reports the hands in each frame. Its work is done off the main thread; [onFrame] is called
/// on that queue.
final class HandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// The names a pair of glasses' camera goes by. Only a camera with one of these in its name is ever taken as
    /// the glasses': the Mac's own camera faces the wrong way and is never used unasked.
    static let glassesNames: [String] = ["xreal", "aura", "viture", "rokid"]

    /// The glasses' camera: an external video device with a glasses name, nil when there is none.
    static func glassesCamera() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        return found.devices.first { isGlasses($0) }
    }

    /// The glasses makers' USB vendor numbers as macOS writes them in a camera's model ("UVC Camera VendorID_13080
    /// ProductID_1082"): XREAL 0x3318, VITURE 0x35CA. The XREAL Aura's camera is listed by macOS as plain "UVC
    /// Camera 0" (seen 16 Nov 2026), with no maker's name in it, so the name alone does not find it.
    static let glassesVendors: [String] = ["vendorid_13080", "vendorid_13770"]

    /// The Mac's built-in camera.
    static func macCamera() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        return found.devices.first
    }

    static func isGlasses(_ device: AVCaptureDevice) -> Bool {
        let name: String = device.localizedName.lowercased()
        if glassesNames.contains(where: { name.contains($0) }) { return true }
        let model: String = device.modelID.lowercased()
        return glassesVendors.contains { model.contains($0) }
    }

    /// Every camera that is not the glasses': the Mac's built-in one first, then iPhones as Continuity Cameras,
    /// then other webcams. These all face the person.
    static func otherCameras() -> [AVCaptureDevice] {
        var out = [AVCaptureDevice]()
        for kind in [AVCaptureDevice.DeviceType.builtInWideAngleCamera, .continuityCamera, .external] {
            let found = AVCaptureDevice.DiscoverySession(deviceTypes: [kind], mediaType: .video, position: .unspecified)
            for device in found.devices where !isGlasses(device) && !out.contains(where: { $0.uniqueID == device.uniqueID }) {
                out.append(device)
            }
        }
        return out
    }

    /// The camera a choice comes to now. The glasses' camera, when the glasses have none macOS can open, falls
    /// back to the Mac's own ([fellBack]), which the windows say in words. Nil when there is no such camera.
    static func resolve(_ choice: HandCameraChoice) -> (device: AVCaptureDevice?, fellBack: Bool) {
        switch choice {
        case .glasses:
            if let glasses = glassesCamera() { return (glasses, false) }
            let other: AVCaptureDevice? = macCamera() ?? otherCameras().first
            return (other, other != nil)
        case .mac:
            return (macCamera() ?? otherCameras().first, false)
        case .device(let id):
            return (otherCameras().first { $0.uniqueID == id }, false)
        }
    }

    /// The camera's width of view, degrees. macOS does not say (AVCaptureDevice.Format.videoFieldOfView is not
    /// there on the Mac), so: the Android app's measured estimate for the XREAL Aura, a common webcam's otherwise.
    static func fovDeg(of device: AVCaptureDevice) -> Double {
        let name: String = device.localizedName.lowercased()
        let xreal: Bool = name.contains("xreal") || name.contains("aura") || device.modelID.lowercased().contains("vendorid_13080")
        return xreal ? HandCameraModel.auraFovDeg : HandCameraModel.unknownFovDeg
    }

    let name: String
    /// The device's own id, as macOS has it.
    let id: String
    let fovDeg: Double
    /// The camera faces the person (any camera but the glasses'): its picture is swapped left to right before
    /// use, so a hand moved to the right moves the pointer to the right.
    let facing: Bool
    var onFrame: ((HandCameraFrame) -> Void)?
    /// A small mirrored copy of the picture, about 10 times a second, while [previewWanted] (on the frames' queue).
    var onPreview: ((CGImage) -> Void)?

    /// The settings window is showing the camera's picture. Set from the main thread, read on the frames' queue.
    var previewWanted: Bool {
        get { previewLock.lock(); defer { previewLock.unlock() }; return wantsPreview }
        set { previewLock.lock(); wantsPreview = newValue; previewLock.unlock() }
    }

    private let previewLock = NSLock()
    private var wantsPreview = false
    private var lastPreviewMs = 0.0
    private lazy var previewContext = CIContext(options: [.cacheIntermediates: false])
    /// The preview's width in pixels and the time between two of them.
    private static let previewWidth = 360.0
    private static let previewGapMs = 100.0

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let frames = DispatchQueue(label: "pocket-xr.hands.frames")
    private let control = DispatchQueue(label: "pocket-xr.hands.session")
    private let request = VNDetectHumanHandPoseRequest()
    /// A point Vision is less sure of than this is not used, and a hand missing one of its seven points is not a hand.
    private static let minConfidence: Float = 0.15
    /// For the log: hands Vision reported, and the least sure point of the last hand that was turned away.
    private var rawSeen = 0
    private var weakest = ""
    /// For the log: how light the picture is, 0 black to 255 white, and the spread between its darkest and lightest
    /// parts. A camera that is covered, or a room too dark, shows here.
    /// The picture is black, or nearly: read by hand tracking for its status line.
    private(set) var dark = false
    private var lightChecks = 0
    private var light = 0.0
    private var spread = 0.0

    /// The light of a frame from a scatter of its brightness samples (the first plane of the picture).
    private func measureLight(_ pixels: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pixels, 0), h = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard w > 16, h > 16 else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, low = 255, high = 0, n = 0
        for y in stride(from: h / 16, to: h, by: h / 16) {
            for x in stride(from: w / 16, to: w, by: w / 16) {
                let v = Int(bytes[y * row + x])
                sum += v; low = min(low, v); high = max(high, v); n += 1
            }
        }
        if n > 0 { light = Double(sum) / Double(n); spread = Double(high - low) }
    }
    /// Frames sooner than this after the last one used are let go (a 60 a second camera is taken at 30).
    private static let minGapMs = 30.0
    /// A detection slower than this (averaged) and only every other frame is used; faster than [fastMs], all again.
    private static let slowMs = 40.0
    private static let fastMs = 30.0

    // Used only on `frames`.
    private var lastUsedMs = 0.0
    private var arrived = 0
    private var averageMs = 0.0
    private var skipping = false
    private var detections = 0
    private var handsSeen = 0
    private var reportStart = 0.0
    private var stopped = false

    /// Nil when the camera cannot be opened.
    init?(device: AVCaptureDevice) {
        self.device = device
        self.name = device.localizedName
        self.id = device.uniqueID
        self.fovDeg = Self.fovDeg(of: device)
        self.facing = !Self.isGlasses(device)
        super.init()
        // One hand: only the first hand aims and gestures, and on the 2018 MacBook Air each hand found costs about
        // 250 ms more a frame (16 Nov 2026: 95 ms with no hand in view, 270 to 400 ms with hands).
        request.maximumHandCount = 1
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            plog("hands: \(name) could not be opened")
            return nil
        }
        session.beginConfiguration()
        // 640 x 480, or the nearest the camera offers: the detector needs no more, and a 2018 Mac has no time for more.
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        // A frame that arrives while the detector is busy is dropped, never queued.
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: frames)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            plog("hands: \(name) gives no frames this app can read")
            return nil
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        plog("hands: opening \(name), \(facing ? "facing the person, mirrored" : "taken as \(Int(fovDeg)) degrees wide")")
        control.async { [session] in session.startRunning() }
    }

    /// Lets the camera go at once. A frame already being looked at may still be reported: whoever listens checks
    /// that this is still its camera.
    func stop() {
        frames.async { [weak self] in self?.stopped = true }
        control.async { [session, name] in
            session.stopRunning()
            plog("hands: \(name) closed")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now: Double = CACurrentMediaTime() * 1000
        arrived += 1
        if now - lastUsedMs < Self.minGapMs { return }
        if skipping && arrived % 2 == 0 { return }
        lastUsedMs = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        let took: Double = CACurrentMediaTime() * 1000 - now
        averageMs = averageMs == 0 ? took : averageMs + 0.1 * (took - averageMs)
        if !skipping && averageMs > Self.slowMs {
            skipping = true
            plog("hands: a detection takes \(Int(averageMs)) ms, using every other frame")
        } else if skipping && averageMs < Self.fastMs {
            skipping = false
            plog("hands: a detection takes \(Int(averageMs)) ms, using every frame again")
        }

        let width = Double(CVPixelBufferGetWidth(pixels))
        let height = Double(max(CVPixelBufferGetHeight(pixels), 1))
        let aspect: Double = width / height
        var hands = [HandPoints]()
        for seen in request.results ?? [] {
            rawSeen += 1
            if let hand = Self.hand(from: seen, aspect: aspect, mirrored: facing) {
                hands.append(hand)
            } else if let all = try? seen.recognizedPoints(.all), let low = all.min(by: { $0.value.confidence < $1.value.confidence }) {
                weakest = "\(low.key.rawValue.rawValue) \(String(format: "%.2f", low.value.confidence))"
            }
        }

        detections += 1
        // About once a second: is there anything to see in the picture at all?
        lightChecks += 1
        if lightChecks % 8 == 1 {
            measureLight(pixels)
            dark = light < 14 && spread < 30
        }
        handsSeen += hands.count
        if reportStart == 0 { reportStart = now }
        if now - reportStart >= 10_000 {
            let seconds: Double = (now - reportStart) / 1000
            let rate = String(format: "%.1f", Double(detections) / seconds)
            let each = String(format: "%.1f", Double(handsSeen) / Double(max(detections, 1)))
            let turnedAway: String = rawSeen > handsSeen ? ", Vision reported \(rawSeen) and \(rawSeen - handsSeen) were too unsure (\(weakest))" : ", Vision reported \(rawSeen)"
            measureLight(pixels)
            plog("hands: \(rate) detections a second at \(Int(width)) x \(Int(height)), \(Int(averageMs)) ms each, \(each) hands a frame\(turnedAway), picture light \(Int(light)) of 255 (spread \(Int(spread)))\(skipping ? ", every other frame" : "")")
            rawSeen = 0
            detections = 0
            handsSeen = 0
            reportStart = now
        }
        onFrame?(HandCameraFrame(hands: hands, timeMs: now, aspect: aspect))
        if previewWanted && now - lastPreviewMs >= Self.previewGapMs {
            lastPreviewMs = now
            if let picture = preview(of: pixels, width: width) { onPreview?(picture) }
        }
    }

    /// The frame made small, and swapped left to right when the camera faces the person.
    private func preview(of pixels: CVPixelBuffer, width: Double) -> CGImage? {
        let scale = CGFloat(min(Self.previewWidth / max(width, 1), 1))
        var image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if facing {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
        }
        return previewContext.createCGImage(image, from: image.extent)
    }

    /// Vision's hand as the seven points hand tracking uses, nil when it is unsure of any of them.
    private static func hand(from seen: VNHumanHandPoseObservation, aspect: Double, mirrored: Bool) -> HandPoints? {
        guard let all = try? seen.recognizedPoints(.all) else { return nil }
        let wanted: [VNHumanHandPoseObservation.JointName] = [.wrist, .thumbTip, .indexTip, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        var points = [(x: Double, y: Double)]()
        for joint in wanted {
            guard let p = all[joint], p.confidence >= minConfidence else { return nil }
            points.append((x: Double(p.location.x), y: Double(p.location.y)))
        }
        let side: HandSide?
        switch seen.chirality {
        case .left: side = .left
        case .right: side = .right
        default: side = nil
        }
        return HandPoints.fromLowerLeft(points, side: side, aspect: aspect, mirrored: mirrored)
    }
}
