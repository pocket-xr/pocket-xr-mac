import PocketXRCore
import SwiftUI

/// The tour's words, in one place. Plain, short, exact; one idea per step. What is untested is said as untested: only
/// the XREAL Aura has been run on a Mac.
enum TourCopy {
    static let windowTitle = "Tour of Pocket XR"
    static let skip = "Skip"
    static let back = "Back"
    static let next = "Next"
    static let finish = "Done"
    static let stateDone = "Done"
    static let stateToDo = "To do"
    static let stateOptional = "Optional"
    static let on = "On"
    static let off = "Off"

    static func stepOf(_ step: TourStep) -> String { "Step \(step.number) of \(Tour.count)" }

    /// A shortcut's keys as the menu shows them ("⌃⌥R"), from the app's one list.
    static func keys(_ id: String) -> String {
        Shortcut.all.first(where: { $0.id == id })?.keys ?? ""
    }

    static func title(_ step: TourStep, ready: Bool) -> String {
        switch step {
        case .welcome: return "Your Mac, all around you"
        case .setup: return "Get set up"
        case .screens: return "Your screens are real displays"
        case .look: return "Look around"
        case .arrange: return "Make the Space yours"
        case .depth: return "3D and Steady mode"
        case .menu: return "Always in your menu bar"
        case .done: return ready ? "You're set" : "Almost there"
        }
    }

    /// What each picture shows, for VoiceOver.
    static func picture(_ step: TourStep, connected: Bool, ready: Bool) -> String {
        switch step {
        case .welcome:
            return "Picture: glass screens floating in an arc above a small Mac, the middle one lit."
        case .setup:
            return connected
                ? "Picture: a Mac joined to glasses by a cable, with light running along it."
                : "Picture: a Mac and glasses, the cable not plugged in yet."
        case .screens:
            return "Picture: the pointer leaves the right edge of the Mac's screen and is on the first floating screen. Then it carries a window across."
        case .look:
            return "Picture: the view turns away and the screens slide out of sight. A press on Control, Option and R brings them back in front."
        case .arrange:
            return "Picture: your screens seen from behind your seat. They grow, come nearer and curve as the controls change."
        case .depth:
            return "Picture: two pictures, one for each eye, come together into screens at depth. Then the screens line up in a row that holds still."
        case .menu:
            return "Picture: the menu opens from the glasses icon in the menu bar. Then the cable is unplugged and the windows glide back onto the Mac's screen."
        case .done:
            return ready ? "Picture: your screens around your Mac, and a tick." : "Picture: your screens around your Mac."
        }
    }

    // 1. Welcome
    static let welcomeBody = "Pocket XR puts your Mac's screens in your glasses, as large screens floating around you. They hold their place as you look around, and your keyboard and trackpad work as always."
    static let welcomeNote = "This tour takes about two minutes. Skip it any time: it stays in the menu."

    // 2. Get set up
    static let setupBody = "Two things are needed; one is optional."
    static let glasses = "Glasses"
    static let glassesUnplugged = "Not plugged in yet. Plug them into a USB-C port that carries video. The tour works without them."
    static func glassesConnected(_ name: String) -> String { "Connected: \(name)." }
    static func glassesDisplay(_ display: String) -> String { "macOS sees their display: \(display)." }
    static let glassesNoDisplay = "macOS does not see their display yet. The port or the cable may not carry video."

    /// What is known for these glasses on a Mac.
    static func support(_ support: Tour.Support, name: String) -> String {
        switch support {
        case .tested:
            return "\(name): works on a Mac, tested by the Pocket XR project."
        case .sameTrackingUntested:
            return "\(name): uses the same head tracking as the Aura. Not tried on a Mac yet."
        case .experimentalTracking:
            return "\(name): screens show. Head tracking is an experimental switch in Settings, untested on a Mac."
        case .screensOnly:
            return "\(name): screens show, without head tracking."
        }
    }

    static let recording = "Screen Recording"
    static let recordingAllowed = "Allowed."
    static let recordingNotAllowed = "Not allowed yet."
    static let recordingWhy = "Pocket XR captures its own virtual screens to draw them in your glasses. Nothing leaves your Mac."
    static let recordingReopen = "macOS asks you to quit and reopen Pocket XR after you allow it."
    static let recordingMonthly = "macOS 15 and later asks again about once a month."
    static let recordingAllow = "Allow"
    static let recordingSettings = "Open System Settings"
    static let login = "Open at login"
    static let loginLine = "Pocket XR starts when you log in to your Mac."

    // 3. Your screens are real displays
    static let screensBody = "macOS sees one to six extra displays, to the right of your own screen. Full screen and Mission Control work on them as on any display."
    static let screensPointer = "Move the pointer off the right edge of your Mac's screen. It is now on the first floating screen."
    static let screensDrag = "Drag a window onto a floating screen."
    static let screensCount = "Change how many screens you have in Settings. It takes effect when Pocket XR opens again."

    // 4. Look around
    static let lookBody = "Screens stay where they are as you turn your head."
    static func lookRecentre() -> String {
        "Lost them, or sitting somewhere new? Recentre brings them back in front of you: press \(keys("recentre")), or pick Recentre in the menu."
    }
    static func lookTry() -> String { "Try it: press \(keys("recentre"))" }
    static let recentre = "Recentre"

    // 5. Make the Space yours
    static let arrangeBody = "Drag a control: the screens in your glasses change as you do."
    static let arrangeSize = "Size"
    static let arrangeDistance = "Distance"
    static let arrangeCurve = "Curve"
    static let arrangeLayout = "Layout"
    static let arrangeNote = "The keys beside each control do the same from anywhere. Or hold Control and Option: moving the pointer carries the screens, scrolling resizes them."

    static func layoutName(_ layout: ArrangeLayout) -> String {
        // The same names as the menu and Settings, for the two screens a new install has.
        SpaceLayout.title(layout, count: 2)
    }

    static func sizeValue(_ degrees: Double) -> String { "\(Int(degrees.rounded()))°" }
    static func distanceValue(_ metres: Double) -> String { String(format: "%.1f m", metres) }
    static func curveValue(_ curve: Double) -> String { SettingsFormat.curve(curve) }

    // 6. 3D and Steady mode
    static let depth3D = "3D"
    static let depth3DLine = "Each eye gets its own picture, so screens sit at real depth."
    static func depth3DNote() -> String {
        "Pocket XR switches the glasses to 3D by itself where they allow it; the Aura does. \(keys("depth")) turns it on and off."
    }
    static let steady = "Steady mode"
    static func steadyLine() -> String {
        "For reading and working: the glasses hold the picture completely still themselves. \(keys("steady")) turns it on and off."
    }
    static let steadyNote = "Works with the XREAL Aura. The One series has not been tried on a Mac yet."

    // 7. Always in your menu bar
    static let menuBody = "The control panel on your Mac's screen has everything in one place. Close it and the glasses icon in the menu bar opens it again, and holds Recentre, Settings, this tour and Send logs."
    static let menuOpen = "Click the glasses icon to open the menu."
    static let menuQuit = "\"Quit and put the glasses back\" returns your glasses to normal."
    static let menuUnplug = "Unplug the glasses and the floating screens go away by themselves. Your windows come back to your Mac's screen."

    // 8. You're set
    static let doneReady = "Your glasses are connected and your screens are showing. Put your glasses on and look up."
    static let doneOpen = "That's the tour. Here is what is still to do:"
    static let doneToSetup = "Back to setup"
    static let doneAgain = "This tour is always in the menu, and in Settings under Help."
    static let doneShortcuts = "Settings lists every shortcut."

    static func remaining(_ item: Tour.Remaining) -> String {
        switch item {
        case .screenRecording: return "Allow Screen Recording, so Pocket XR can draw your screens."
        case .plugInGlasses: return "Plug in your glasses."
        case .screensNotShowing: return "Your glasses are connected, but the screens are not showing on them yet. The menu says where things stand."
        }
    }
}
