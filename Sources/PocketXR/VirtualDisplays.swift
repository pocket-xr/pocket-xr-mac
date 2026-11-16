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

    /// Puts the virtual displays in a row to the right of the Mac's main screen, and the glasses' own display below
    /// that row, out of the pointer's way: the pointer goes from the Mac's screen straight onto the virtual displays.
    func arrange(glasses: CGDirectDisplayID?) {
        guard !screens.isEmpty else { return }
        // A new display can take a moment before macOS lets it be moved.
        Thread.sleep(forTimeInterval: 0.5)
        let main = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(main)
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            plog("virtual displays: could not start arranging")
            return
        }
        var x = Int32(mainBounds.maxX)
        let top = Int32(mainBounds.minY)
        for s in screens {
            CGConfigureDisplayOrigin(config, s.id, x, top)
            x += Int32(s.width)
        }
        if let g = glasses {
            // Below the row, under the Mac's screen, so the only way onto it is a deliberate trip down.
            CGConfigureDisplayOrigin(config, g, Int32(mainBounds.minX), Int32(mainBounds.maxY) + 1080)
        }
        let rc = CGCompleteDisplayConfiguration(config, .forSession)
        plog("virtual displays: arranged right of the main screen (\(rc == .success ? "done" : "error \(rc.rawValue)"))")
    }
}
