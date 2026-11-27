import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import PocketXRCore
import ScreenCaptureKit

/// Pictures of one display, with ScreenCaptureKit: each new frame's IOSurface becomes a Metal texture with no copy,
/// and the renderer takes the newest. The cursor is in the picture while it is on that display.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    private let device: MTLDevice
    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: MTLTexture?
    /// The frame's buffer is held with its texture, so ScreenCaptureKit does not draw the next frame into it while
    /// the renderer reads it (queueDepth 4 leaves it enough others).
    private var latestBuffer: CVPixelBuffer?
    private let queue: DispatchQueue
    private(set) var frames = 0
    private var config: SCStreamConfiguration?
    /// Whether macOS's pointer is in the picture: not while Pocket XR draws it itself (Quick pointer).
    private var cursorShown = true
    /// 0.5.13: the glasses window's number, left out of the picture (see [leaveOut]); 0 for none yet.
    private var leftOut = 0
    private var scDisplay: SCDisplay?

    init(displayID: CGDirectDisplayID, device: MTLDevice) {
        self.displayID = displayID
        self.device = device
        queue = DispatchQueue(label: "Pocket XR capture \(displayID)", qos: .userInteractive)
    }

    /// The newest picture, nil until the first frame.
    var texture: MTLTexture? { lock.lock(); defer { lock.unlock() }; return latest }

    /// Starts capturing. A new virtual display can take a moment to show up in ScreenCaptureKit's list, so it looks
    /// for up to 5 s.
    func start(width: Int, height: Int, hz: Int = 60) async throws {
        let showsCursor = cursorShown
        var found: SCDisplay?
        for _ in 0..<10 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            found = content.displays.first { $0.displayID == self.displayID }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let display = found else {
            plog("capture: display \(displayID) not in ScreenCaptureKit's list")
            throw CaptureError.noDisplay
        }
        scDisplay = display
        let filter = try await Self.filter(display, leavingOut: leftOut)
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(30, hz)))
        cfg.queueDepth = 4
        cfg.showsCursor = showsCursor
        cfg.capturesAudio = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        config = cfg
        plog("capture: display \(displayID) streaming \(width)x\(height), up to \(hz) frames a second\(showsCursor ? "" : ", pointer left out")")
        // Quick pointer turned on or off while the stream was starting.
        if cursorShown != showsCursor {
            let want = cursorShown
            cursorShown = showsCursor
            setShowsCursor(want)
        }
    }

    /// 0.5.13 (XREAL 1S on an M4 Pro, 0.5.12: one screen showed "infinity screens becoming smaller and smaller"): a
    /// screen that has Pocket XR's glasses window in it shows its own picture inside itself, without end. That window
    /// ([windowNumber]) is left out of the picture, whatever macOS does with the displays. Other Pocket XR windows that
    /// belong on a screen (the Launcher, hand calibration) stay in.
    func leaveOut(windowNumber: Int) {
        guard windowNumber != leftOut else { return }
        leftOut = windowNumber
        // Not started yet: start() takes it from here.
        guard let s = stream, let d = scDisplay else { return }
        let id = displayID
        Task {
            do { try await s.updateContentFilter(Self.filter(d, leavingOut: windowNumber)) } catch {
                plog("capture: display \(id): the glasses window could not be left out: \(error.localizedDescription)")
            }
        }
    }

    private static func filter(_ display: SCDisplay, leavingOut windowNumber: Int) async throws -> SCContentFilter {
        guard windowNumber > 0 else { return SCContentFilter(display: display, excludingWindows: []) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let glasses = content.windows.filter { Int($0.windowID) == windowNumber }
        return SCContentFilter(display: display, excludingWindows: glasses)
    }

    /// Puts macOS's pointer into the picture or takes it out, on a running stream.
    func setShowsCursor(_ on: Bool) {
        guard on != cursorShown else { return }
        cursorShown = on
        // Not started yet: start() takes it from here.
        guard let s = stream, let cfg = config else { return }
        cfg.showsCursor = on
        let id = displayID
        Task {
            do { try await s.updateConfiguration(cfg) } catch {
                plog("capture: display \(id): the pointer could not be \(on ? "put back" : "left out"): \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    enum CaptureError: Error { case noDisplay }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only complete frames carry a new picture; idle ones mean "nothing changed".
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else { return }
        lock.lock()
        latest = tex
        latestBuffer = pb
        frames += 1
        lock.unlock()
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        plog("capture: display \(displayID) stopped: \(error.localizedDescription)")
    }
}
