import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import PocketXRCore

/// Keeps this Mac fully awake while a phone shows it. When the phone wakes a sleeping Mac (Wake-on-LAN), macOS
/// wakes it only halfway (a "dark wake": screens off, back to sleep in under a minute), and with its screens off
/// there is nothing to capture. A stream starting counts as someone using the Mac: the screens come on and the
/// Mac and its screens stay awake until the last stream ends.
enum HostAwake {
    private static let lock = NSLock()
    private static var streams = 0
    private static var activity: IOPMAssertionID = 0
    private static var keepOn: IOPMAssertionID = 0

    /// A stream is starting: wake the screens (as a key press would) and keep the Mac and its screens awake.
    static func streamStarted() {
        lock.lock(); defer { lock.unlock() }
        let wasAsleep = screensAsleep
        // Declared each time: it is what turns a dark wake into a full one, and lights the screens.
        let r = IOPMAssertionDeclareUserActivity("Pocket XR: a phone is showing this Mac" as CFString, kIOPMUserActiveLocal, &activity)
        streams += 1
        if streams == 1 {
            let k = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Pocket XR: a phone is showing this Mac" as CFString, &keepOn)
            if k != kIOReturnSuccess { keepOn = 0 }
        }
        plog("host: keeping this Mac awake while the phone shows it\(wasAsleep ? " (its screen was asleep: woken)" : "")\(r == kIOReturnSuccess ? "" : " (could not wake the screen: \(r))")")
    }

    /// A stream has ended: once none is left, the Mac may sleep again on its usual timers.
    static func streamEnded() {
        lock.lock(); defer { lock.unlock() }
        guard streams > 0 else { return }
        streams -= 1
        guard streams == 0 else { return }
        if keepOn != 0 { IOPMAssertionRelease(keepOn); keepOn = 0 }
        if activity != 0 { IOPMAssertionRelease(activity); activity = 0 }
        plog("host: no phone is showing this Mac: it may sleep again")
    }

    /// The main screen is asleep (or the Mac is in a dark wake).
    static var screensAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}
