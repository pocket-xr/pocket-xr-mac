import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import PocketXRCore

/// "Stay awake on the power adapter" (off by default): while this Mac is on its adapter, it does not go to sleep when
/// left idle, so Tailscale and the like keep running and a phone can reach it from anywhere, with no wake packet (which
/// only travels on the local network). The screen may still sleep. Dropped on battery and when switched off. Closing a
/// MacBook's lid still sleeps it unless a display is connected. macOS drops the assertion itself if Pocket XR quits.
/// Main thread only: set from the controller, and the power source callback comes on the main run loop.
enum StayAwake {
    private static var enabled = false
    private static var assertion: IOPMAssertionID = 0
    private static var source: CFRunLoopSource?

    static func set(_ on: Bool) {
        if on != enabled { plog("stay awake on the power adapter: \(on ? "on" : "off")") }
        enabled = on
        if on, source == nil {
            if let s = IOPSNotificationCreateRunLoopSource({ _ in StayAwake.update() }, nil)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
                source = s
            }
        } else if !on, let s = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            source = nil
        }
        update()
    }

    /// Whether this Mac runs on its power adapter now. A Mac with no battery reports "AC Power" too; if macOS gives no
    /// answer it is taken as the adapter, as only a laptop has anything else.
    static var onAdapter: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private static func update() {
        let adapter = onAdapter
        let hold = StayAwakeRule.holds(enabled: enabled, onAdapter: adapter)
        if hold, assertion == 0 {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                StayAwakeRule.assertionName as CFString, &id)
            if r == kIOReturnSuccess {
                assertion = id
                plog(StayAwakeRule.line(holding: true, enabled: enabled, onAdapter: adapter))
            } else {
                plog("stay awake: macOS refused the assertion (\(r))")
            }
        } else if !hold, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            plog(StayAwakeRule.line(holding: false, enabled: enabled, onAdapter: adapter))
        }
    }
}
