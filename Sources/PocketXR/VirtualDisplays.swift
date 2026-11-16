import AppKit
import CoreGraphics
import CVirtualDisplay
import PocketXRCore

/// The screens the Mac's apps live on while Pocket XR runs: 1 to 3 virtual displays, each 1920x1080 at 60 Hz.
///
/// Every use of CoreGraphics' private virtual display classes is here. They are made once per session and never
/// added or removed while capture runs: Apple bug FB17797423 makes a new capture stream pick the wrong display after a
/// virtual display comes back. When this object goes away, so do the displays, and macOS moves their windows back to
/// the Mac's own screen.
final class VirtualDisplays {
    struct Screen {
        let display: CGVirtualDisplay
        let id: CGDirectDisplayID
        let width: Int
        let height: Int
    }

    private(set) var screens = [Screen]()
    private let queue = DispatchQueue(label: "Pocket XR virtual displays")

    /// Makes [count] displays of [width]x[height]. Logs and returns fewer if macOS refuses.
    init(count: Int, width: Int = 1920, height: Int = 1080, hiDPI: Bool = false) {
        for i in 0..<count {
            let d = CGVirtualDisplayDescriptor()
            d.queue = queue
            d.name = count == 1 ? "Pocket XR" : "Pocket XR \(i + 1)"
            // HiDPI needs a backing twice the size.
            d.maxPixelsWide = UInt32(width * (hiDPI ? 2 : 1))
            d.maxPixelsHigh = UInt32(height * (hiDPI ? 2 : 1))
            // About a 27 inch screen at this size, so macOS picks sensible text sizes.
            d.sizeInMillimeters = CGSize(width: 600, height: 340)
            d.vendorID = 0x5058 // "PX"
            d.productID = 0x0100 + UInt32(i)
            d.serialNum = 0x0001 + UInt32(i)
            d.terminationHandler = { _, _ in plog("virtual display \(i + 1): ended by macOS") }
            guard let display = CGVirtualDisplay(descriptor: d) else {
                plog("virtual display \(i + 1): macOS would not make it")
                continue
            }
            let s = CGVirtualDisplaySettings()
            s.hiDPI = hiDPI ? 1 : 0
            s.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)]
            guard display.apply(s) else {
                plog("virtual display \(i + 1): its 1920x1080 mode was refused")
                continue
            }
            screens.append(Screen(display: display, id: display.displayID, width: width, height: height))
            plog("virtual display \(i + 1): id \(display.displayID), \(width)x\(height) at 60 Hz\(hiDPI ? ", HiDPI" : "")")
        }
    }

    /// Puts the virtual displays to the right of the Mac's own screen, laid out as the screens look in the glasses
    /// ([panels], see DisplayGrid): side by side there is left and right here, stacked there is above and below
    /// here, so the pointer crosses between them the way the eye expects. The glasses' own display goes corner to
    /// corner with the far end, out of the pointer's way. Does nothing when the displays are already there.
    func arrange(glasses: CGDirectDisplayID?, panels: [PanelPlacement]) {
        guard !screens.isEmpty else { return }
        // The Mac's own screen is the anchor, found by what it is and not by "the main display": macOS made a
        // virtual display the main one (16 Nov 2026), the row was then laid out from itself, and the laptop's screen
        // ended up touching nothing, where the pointer could not reach it.
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        let ours = Set(screens.map(\.id))
        let real: [CGDirectDisplayID] = ids.prefix(Int(n)).filter { id in !ours.contains(id) && glasses != id }
        let builtIn: CGDirectDisplayID? = real.first(where: { CGDisplayIsBuiltin($0) != 0 })
        let own: CGDirectDisplayID = builtIn ?? real.first ?? CGMainDisplayID()
        let ownWidth = Int(CGDisplayBounds(own).width)

        let grid = DisplayGrid.origins(panels: panels, sizes: screens.map { (width: $0.width, height: $0.height) })
        var wanted: [(id: CGDirectDisplayID, x: Int, y: Int)] = [(id: own, x: 0, y: 0)]
        var right = ownWidth, bottom = 0
        for (i, s) in screens.enumerated() {
            let x = ownWidth + grid[i].x, y = grid[i].y
            wanted.append((id: s.id, x: x, y: y))
            right = max(right, x + s.width)
            bottom = max(bottom, y + s.height)
        }
        // Corner to corner with the far end: joined, as macOS wants, with no edge to cross onto it.
        if let g = glasses { wanted.append((id: g, x: right, y: bottom)) }

        let there = wanted.allSatisfy { w in
            let b = CGDisplayBounds(w.id)
            return Int(b.minX) == w.x && Int(b.minY) == w.y
        }
        if there { return }
        // A new display can take a moment before macOS lets it be moved.
        Thread.sleep(forTimeInterval: 0.5)
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            plog("virtual displays: could not start arranging")
            return
        }
        // The Mac's screen at 0,0 is also the main display again: the menu bar and new windows stay on it.
        for w in wanted { CGConfigureDisplayOrigin(config, w.id, Int32(w.x), Int32(w.y)) }
        let rc = CGCompleteDisplayConfiguration(config, .forSession)
        let places: [String] = wanted.map { w in
            let b = CGDisplayBounds(w.id)
            return "\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))"
        }
        plog("virtual displays: arranged beside the Mac's screen (\(rc == .success ? "done" : "error \(rc.rawValue)")): \(places.joined(separator: " | "))")
    }
}
