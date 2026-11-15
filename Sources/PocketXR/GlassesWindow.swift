import AppKit
import Metal
import PocketXRCore
import QuartzCore

/// The view that covers the glasses' display: a CAMetalLayer at the screen's pixel size, redrawn on each refresh of
/// the glasses' own display (NSView.displayLink, macOS 14), so it runs at whatever rate the glasses run.
final class GlassesView: NSView {
    let metalLayer = CAMetalLayer()
    var onFrame: (@MainActor (CAMetalDrawable) -> Void)?
    private var link: CADisplayLink?
    private(set) var fps: Double = 0
    private var fpsCount = 0
    private var fpsStart = CACurrentMediaTime()

    init(frame: NSRect, device: MTLDevice) {
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        link?.invalidate()
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let d = metalLayer.nextDrawable() else { return }
        onFrame?(d)
        fpsCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            fps = Double(fpsCount) / (now - fpsStart)
            fpsCount = 0
            fpsStart = now
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

/// A borderless window over the whole glasses display, above the menu bar, that the mouse passes through.
final class GlassesWindow: NSWindow {
    let glassesView: GlassesView

    init(screen: NSScreen, device: MTLDevice) {
        glassesView = GlassesView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = glassesView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func shut() {
        glassesView.stop()
        orderOut(nil)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The glasses' display: a screen whose name says XREAL, VITURE and the like (not one of Pocket XR's own).
    static var glasses: NSScreen? {
        screens.first { Glasses.isGlassesScreenName($0.localizedName) && !$0.localizedName.hasPrefix("Pocket XR") }
    }
}
