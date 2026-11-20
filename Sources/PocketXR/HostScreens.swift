import Foundation
import CoreGraphics
import CVirtualDisplay
import PocketXRCore

/// The virtual displays the phone's PC screens show, one per host (up to three), each at the phone window's shape.
/// Ported from the Pocket XR PC helper for Mac's VirtualScreens (build 9), where it was measured on the Air, macOS 14.8:
/// - macOS gives a new display the first free display id, so each is made once and kept while Pocket XR runs (it
///   also keeps clear of Apple bug FB17797423: capture picking the wrong display after one comes back).
/// - While no stream uses one, it mirrors the built-in screen: macOS then lists only the built-in screen for windows,
///   and the built-in keeps its own mode. A stream's screen is resized while still mirrored, then one change brings it
///   out to the right of the Mac's displays and mirrors the rest again; a check every few seconds mirrors any idle one
///   that came out by itself.
/// - A new display became the main display and the built-in screen changed mode (1280x800 to 1440x900) while it was
///   there: the built-in's own mode is put back in the same change.
/// - A change that moves the Mac's own displays takes ~10 s even when they are already in place: they are moved only
///   when out of place.
final class HostScreens: @unchecked Sendable {
    struct Mode: Equatable, CustomStringConvertible {
        let width: Int, height: Int, fps: Int
        var description: String { "\(width)x\(height)@\(fps)" }
        /// The phone's window as asked: each side 360..3840, even, 30..120 Hz.
        static func clamped(_ w: Int, _ h: Int, _ fps: Int) -> Mode {
            Mode(width: max(360, min(3840, w)) & ~1, height: max(360, min(3840, h)) & ~1, fps: max(30, min(120, fps)))
        }
    }

    private var displays: [Int: CGVirtualDisplay] = [:]
    private var streaming: Set<Int> = []
    private var expecting: [Int: Date] = [:]
    private var out: Set<Int> { streaming.union(expecting.keys) }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "host-screens")
    private var saved: [(id: UInt32, x: Int32, y: Int32, width: Int32)] = []
    private var builtinMode: CGDisplayMode?
    private var builtinId: CGDirectDisplayID = 0
    private var timer: DispatchSourceTimer?

    static let vendor: UInt32 = 0x5058  // "PX"
    static let product: UInt32 = 0x0310 // the PC helper's are 0x0300
    static let idle = Mode(width: 1280, height: 720, fps: 30)

    init() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 3)
        t.setEventHandler { [weak self] in self?.checkIdle() }
        t.resume()
        timer = t
    }

    /// Screen [index] out for a stream at [mode]. Its display id once there; nil if it could not be made.
    func stream(_ index: Int, _ mode: Mode) -> CGDirectDisplayID? {
        lock.lock(); defer { lock.unlock() }
        return bringOut(index, mode, until: nil)
    }

    /// Screen [index] out at [mode] for a stream the phone is about to start (screen-prepare); back to mirroring if
    /// none starts within a minute.
    func prepare(_ index: Int, _ mode: Mode) -> CGDirectDisplayID? {
        lock.lock(); defer { lock.unlock() }
        return bringOut(index, mode, until: Date().addingTimeInterval(60))
    }

    /// Screen [index] back to waiting (mirrored).
    func idle(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let display = displays[index] else { return }
        streaming.remove(index)
        // Out for another minute, then mirrored (checkIdle): a phone that reconnects finds it ready, and a phone
        // retrying does not make the Mac's screens change again each time.
        expecting[index] = Date().addingTimeInterval(60)
        plog("host: screen \(index): display \(display.displayID) stream ended: stays out for a minute")
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        guard !displays.isEmpty else { return }
        streaming.removeAll()
        expecting.removeAll()
        displays.removeAll()
        Thread.sleep(forTimeInterval: 1)
        arrange()
    }

    private func made(_ index: Int) -> CGVirtualDisplay? {
        if let d = displays[index] { return d }
        if displays.isEmpty { rememberMacDisplays() }
        let d = CGVirtualDisplayDescriptor()
        d.queue = queue
        d.name = "Pocket XR PC screen \(index)"
        d.maxPixelsWide = 3840
        d.maxPixelsHigh = 3840
        d.sizeInMillimeters = CGSize(width: 1280 * 25.4 / 96, height: 720 * 25.4 / 96) // ~96 dpi: text at its usual size
        d.vendorID = Self.vendor
        d.productID = Self.product
        d.serialNum = UInt32(index)
        d.terminationHandler = { _, _ in plog("host: screen \(index): ended by macOS") }
        guard let display = CGVirtualDisplay(descriptor: d) else {
            plog("host: screen \(index): macOS did not make the virtual display")
            return nil
        }
        apply(display, Self.idle)
        displays[index] = display
        for _ in 0..<30 where !Self.active().contains(display.displayID) { Thread.sleep(forTimeInterval: 0.1) }
        plog("host: screen \(index): display \(display.displayID) made")
        return display
    }

    private func bringOut(_ index: Int, _ mode: Mode, until: Date?) -> CGDirectDisplayID? {
        let start = Date()
        guard let display = made(index) else { return nil }
        let id = display.displayID
        let isOut = out.contains(index) && Self.active().contains(id)
        if let until { expecting[index] = until } else { expecting[index] = nil; streaming.insert(index) }
        if isOut, Int(CGDisplayBounds(id).width) == mode.width, Int(CGDisplayBounds(id).height) == mode.height {
            plog("host: screen \(index): display \(id) already out at \(mode)")
            return id
        }
        apply(display, mode)
        Thread.sleep(forTimeInterval: 0.3)
        arrange()
        for _ in 0..<40 where !Self.active().contains(id) || Int(CGDisplayBounds(id).width) != mode.width { Thread.sleep(forTimeInterval: 0.1) }
        plog(String(format: "host: screen %ld: display %u out at %ldx%ld (%@ asked), %.1f s", index, id,
                    Int(CGDisplayBounds(id).width), Int(CGDisplayBounds(id).height), "\(mode)", Date().timeIntervalSince(start)))
        return id
    }

    private func checkIdle() {
        guard lock.try() else { return }
        defer { lock.unlock() }
        let now = Date()
        let expired = expecting.filter { $0.value < now }.map(\.key)
        for i in expired { expecting[i] = nil }
        let active = Self.active()
        let stray = displays.filter { !out.contains($0.key) && active.contains($0.value.displayID) }
        guard !expired.isEmpty || !stray.isEmpty else { return }
        if !expired.isEmpty { plog("host: screens \(expired.sorted()): no stream came; mirrored again") }
        if !stray.isEmpty { plog("host: screens \(stray.keys.sorted()) came out of mirroring: mirrored again") }
        arrange()
    }

    private func apply(_ display: CGVirtualDisplay, _ mode: Mode) {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(mode.width), height: UInt(mode.height), refreshRate: CGFloat(mode.fps))]
        if !display.apply(settings) { plog("host: display \(display.displayID): \(mode) not taken") }
    }

    /// One display change: idle screens mirror the built-in, streaming ones out to the right of the Mac's displays (in
    /// screen order), the Mac's displays back where they were if they moved, the built-in's mode back.
    private func arrange() {
        let online = Self.online()
        let macIds = saved.map(\.id).filter { online.contains($0) }
        let master = builtinId != 0 && online.contains(builtinId) ? builtinId : (macIds.first ?? CGMainDisplayID())
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        var changed = false
        let keep = saved.filter { online.contains($0.id) }
        let outSet = out
        let outIds = displays.filter { outSet.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value.displayID)
        var placed = keep.map { (id: $0.id, x: $0.x, y: $0.y) }
        var x = keep.map { $0.x + $0.width }.max() ?? 0
        for id in outIds {
            placed.append((id: id, x: x, y: 0))
            x += Int32(CGDisplayPixelsWide(id))
        }
        let macMoved = placed.contains { p in
            keep.contains { $0.id == p.id } && (Int32(CGDisplayBounds(p.id).origin.x) != p.x || Int32(CGDisplayBounds(p.id).origin.y) != p.y)
        }
        for p in placed where macMoved || !keep.contains(where: { $0.id == p.id }) {
            CGConfigureDisplayOrigin(config, p.id, p.x, p.y)
            changed = true
        }
        for (index, display) in displays {
            let id = display.displayID
            if outSet.contains(index) {
                if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay); changed = true }
            } else if CGDisplayMirrorsDisplay(id) != master {
                CGConfigureDisplayMirrorOfDisplay(config, id, master)
                changed = true
            }
        }
        if builtinId != 0, let wanted = builtinMode, let now = CGDisplayCopyDisplayMode(builtinId),
           now.width != wanted.width || now.height != wanted.height || now.pixelWidth != wanted.pixelWidth {
            CGConfigureDisplayWithDisplayMode(config, builtinId, wanted, nil)
            changed = true
        }
        if changed {
            let r = CGCompleteDisplayConfiguration(config, .forSession)
            if r != .success { plog("host: display change: error \(r.rawValue)") }
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }

    private func rememberMacDisplays() {
        let active = Self.active()
        let main = CGMainDisplayID()
        let origin = CGDisplayBounds(main).origin
        saved = active.map { id in
            let b = CGDisplayBounds(id)
            return (id: id, x: Int32(b.origin.x - origin.x), y: Int32(b.origin.y - origin.y), width: Int32(b.width))
        }
        builtinId = active.first { CGDisplayIsBuiltin($0) != 0 } ?? 0
        builtinMode = builtinId != 0 ? CGDisplayCopyDisplayMode(builtinId) : nil
    }

    static func active() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }

    static func online() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }
}
