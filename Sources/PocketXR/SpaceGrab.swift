import AppKit

/// Moving and resizing the Space from anywhere, hands on the trackpad: hold Control and Option, and moving the
/// pointer carries the whole Space with it, scrolling makes the screens larger or smaller. The same two keys as every
/// Pocket XR shortcut. Mouse events seen from other apps need no permission (key events would).
@MainActor
final class SpaceGrab {
    private let enabled: () -> Bool
    private let move: (_ yawDeg: Double, _ pitchDeg: Double) -> Void
    private let resize: (_ byDeg: Double) -> Void
    private var monitors = [Any]()
    /// Pointer travel since the keys went down, in points: the Space starts to follow only past [deadZone], so the
    /// hand's small movements while pressing a shortcut do not move it.
    private var travelled = 0.0
    private var lastAt = 0.0
    private static let deadZone = 18.0
    /// Degrees of turn for a point of pointer travel.
    private static let degreesPerPoint = 0.045
    private static let degreesPerScroll = 0.12

    init(enabled: @escaping () -> Bool, move: @escaping (Double, Double) -> Void, resize: @escaping (Double) -> Void) {
        self.enabled = enabled
        self.move = move
        self.resize = resize
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(m) }
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }

    private func handle(_ e: NSEvent) {
        let keys = e.modifierFlags.intersection([.control, .option, .command, .shift])
        guard keys == [.control, .option], enabled() else {
            travelled = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAt > 0.4 { travelled = 0 } // the keys were let go and pressed again
        lastAt = now
        switch e.type {
        case .mouseMoved:
            let dx = Double(e.deltaX), dy = Double(e.deltaY)
            if travelled < Self.deadZone {
                travelled += (dx * dx + dy * dy).squareRoot()
                return
            }
            // Pointer right carries the Space right (left is positive), pointer up carries it up (deltaY grows down).
            move(-dx * Self.degreesPerPoint, -dy * Self.degreesPerPoint)
        case .scrollWheel:
            let dy = Double(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8)
            if dy != 0 { resize(dy * Self.degreesPerScroll) }
        default:
            break
        }
    }
}
