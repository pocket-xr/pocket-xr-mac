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

    /// Whether Air-family glasses were on USB at the last look (AppController sets it each time the screens change).
    /// While they are, a screen named just "Air" is theirs: macOS gives the first XREAL Air's display no maker's name.
    static var airOnUsb = false

    /// Whether this screen is the glasses' display (see Glasses.isGlassesScreen): never the built-in screen, never one
    /// of Pocket XR's own floating screens.
    var isGlassesScreen: Bool {
        Glasses.isGlassesScreen(name: localizedName, builtIn: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                                airOnUsb: NSScreen.airOnUsb)
    }

    /// Whether this is one of Pocket XR's own floating screens (which can only be seen in the glasses).
    var isPocketXRScreen: Bool { localizedName.hasPrefix("Pocket XR") }

    /// The glasses' display: a screen whose name says XREAL, VITURE and the like, or "Air" while an Air is on USB.
    static var glasses: NSScreen? {
        screens.first { $0.isGlassesScreen }
    }

    /// The Mac's own screen, where Pocket XR's windows belong: the built-in one, else the first that is neither the
    /// glasses nor one of Pocket XR's floating screens (which can only be seen in the glasses).
    static var own: NSScreen? {
        let real = screens.filter { !$0.isGlassesScreen && !$0.isPocketXRScreen }
        return real.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false } ?? real.first ?? main
    }
}

extension NSWindow {
    /// Puts the window in the middle of [screen], whichever screen the pointer or the last window was on.
    /// Brings a shown window back to the Mac's own screen when it is not on it. macOS moves windows about when
    /// displays come and go, as they do when the glasses are plugged in and switch to 3D, and one left on the glasses
    /// or on a floating screen cannot be seen (the tour was, 16 Nov 2026).
    func keepOnOwnScreen(_ what: String) {
        guard isVisible, let own = NSScreen.own else { return }
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        if own.frame.contains(mid) { return }
        plog("\(what): was on \(screen?.localizedName ?? "no screen"), moved to \(own.localizedName)")
        centre(on: own)
        orderFrontRegardless()
    }

    func centre(on screen: NSScreen?) {
        guard let area = screen?.visibleFrame else { center(); return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }
}
