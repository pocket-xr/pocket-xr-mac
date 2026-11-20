import Combine
import Foundation
import PocketXRCore

/// The settings, kept in UserDefaults as one JSON value. The windows (SwiftUI) bind to `s`; the controller watches it.
@MainActor
final class SettingsStore: ObservableObject {
    nonisolated static let key = "settings_v2"
    private let defaults: UserDefaults?

    @Published var s: SpaceSettings {
        didSet {
            let c = s.clamped
            if c != s { s = c; return }
            guard s != oldValue else { return }
            save()
        }
    }

    /// [defaults] nil keeps the settings in memory only (previews and the tour's pictures rendered to files).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key), let loaded = try? JSONDecoder().decode(SpaceSettings.self, from: data) {
            s = loaded.clamped
        } else {
            s = SpaceSettings()
        }
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The settings as a file's contents (Save settings to a file).
    func exported() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(s)) ?? Data()
    }

    /// Takes settings from a file's contents; false if it is not a Pocket XR settings file.
    @discardableResult
    func restore(from data: Data) -> Bool {
        guard let loaded = try? JSONDecoder().decode(SpaceSettings.self, from: data) else { return false }
        s = loaded.clamped
        return true
    }

    func reset() {
        var fresh = SpaceSettings()
        fresh.tourSeen = s.tourSeen
        s = fresh
    }
}

/// What is true right now, for the windows to show. Written only by the controller, on the main thread.
@MainActor
final class AppState: ObservableObject {
    /// The glasses' name, nil with none plugged in.
    @Published var glassesName: String?
    @Published var glassesFamily: Glasses.Family?
    /// The glasses' display as macOS has it, such as "3840 x 1080, 60 Hz"; nil while it is not there.
    @Published var displayText: String?
    /// The glasses' picture is 3D side by side now.
    @Published var stereo = false
    /// Frames drawn on the glasses a second.
    @Published var fps = 0.0
    /// Head tracking reports are arriving.
    @Published var trackingOn = false
    /// Head tracking reports a second.
    @Published var imuHz = 0
    /// The gyro's bias has been learnt from stillness.
    @Published var biasReady = false
    /// Where the head points against the recentred forward, degrees (left and up positive).
    @Published var yawDeg = 0.0
    @Published var pitchDeg = 0.0
    /// The glasses' settings link is open.
    @Published var linkOpen = false
    /// The glasses' settings are being changed.
    @Published var busy = false
    /// Steady mode is on (the glasses hold the picture themselves).
    @Published var steady = false
    /// These glasses can do Steady mode.
    @Published var steadyAvailable = false
    @Published var screenRecordingAllowed = false
    /// Virtual displays that exist now.
    @Published var virtualScreens = 0
    /// Screens captured and showing a picture.
    @Published var capturing = 0
    /// The pointer has been on a virtual display this session, and a window has been seen on one (the tour's ticks).
    @Published var pointerVisitedScreen = false
    @Published var recentred = false
    /// One line saying where things stand, as the menu shows it.
    @Published var statusLine = "Plug in your glasses."
    /// The screen count or text sharpness was changed and needs Pocket XR opened again.
    @Published var needsRestart = false
    /// The screens as they are drawn now: where each sits in the Space (moved by hand included), one per screen.
    @Published var panels = [PanelPlacement]()
    /// The glasses' view: each eye's field of view up and down, degrees, and its width over its height.
    @Published var viewFovYDeg = 38.0
    @Published var viewAspect = 16.0 / 9
    /// Every display as macOS has arranged it, for a map of where the pointer can go.
    @Published var displayTiles = [DisplayTile]()
    /// The floating screen the pointer is on (an index into the floating screens), nil on the Mac's own screen.
    @Published var pointerScreen: Int?
    /// The launcher is showing on a floating screen.
    @Published var launcherOpen = false
    /// Pocket mode: the Mac's own screen is black and the pointer is kept on the floating screens.
    @Published var pocketMode = false
    /// A game controller is connected: its name, else nil.
    @Published var controllerName: String?
    /// Hand tracking: running, how many hands are seen now, and one line on where it stands for the windows to show
    /// ("Looking for the glasses' camera", "2 hands", "The camera is not allowed yet").
    @Published var handsRunning = false
    @Published var handsSeen = 0
    @Published var handsStatus = ""
    /// The glasses have a camera macOS can open (found by name among the video devices).
    @Published var handsCameraFound = false
    /// macOS permissions: the camera (hand tracking), and Accessibility (a pinch clicking for you).
    @Published var cameraAllowed = false
    @Published var accessibilityAllowed = false
    /// Shortcuts macOS would not give Pocket XR (by id): another app may already use their keys.
    @Published var shortcutsTaken = Set<String>()
    /// Goes up when a shortcut's keys change, so the windows show the new keys.
    @Published var shortcutsVersion = 0
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

/// One display on the map of displays: the Mac's own screen or a floating screen. The glasses' own display is
/// left out, as nothing is to be done on it.
struct DisplayTile: Identifiable, Equatable {
    /// -1 the Mac's own screen, else the floating screen's index (0 is "Screen 1").
    let id: Int
    let title: String
    /// Where macOS has it, in display points: x right, y down, the Mac's own screen at 0,0.
    let frame: CGRect
    var isOwn: Bool { id < 0 }
}

/// A change to the Space made from a menu, a shortcut or a window.
enum SpaceAdjust: CaseIterable {
    case bigger, smaller, nearer, further, moreCurve, lessCurve, nextLayout
}

/// What the windows can ask the app to do.
@MainActor
protocol AppActions: AnyObject {
    func recentre()
    func adjust(_ a: SpaceAdjust)
    func setSteady(_ on: Bool)
    /// Moves the whole Space by hand, degrees (left and up positive). Added to what is already there.
    func nudgeSpace(yawDeg: Double, pitchDeg: Double)
    /// Moves one screen by hand (its index), degrees, added to where it already is.
    func nudgeScreen(_ index: Int, yawDeg: Double, pitchDeg: Double)
    /// Puts every screen moved by hand back in its place in the layout.
    func resetScreenMoves()
    /// Puts the pointer in the middle of a floating screen (its index), or of the Mac's own screen with nil.
    func movePointer(toScreen index: Int?)
    func openControlPanel()
    /// Shows the launcher on the floating screen the pointer is on (the first one when it is on the Mac's screen),
    /// or hides it.
    func toggleLauncher()
    func setPocketMode(_ on: Bool)
    /// Opens the next PC screen (PcScreens): a screen of the user's PC on a floating screen.
    func openPcScreen()
    /// Starts or stops hand tracking now (the setting `handsOn` is what starts it with the glasses).
    func setHands(_ on: Bool)
    /// Hand tracking's pointer: aims the pointer along a ray given in the head's own frame, degrees (left and up
    /// positive, 0,0 straight ahead through the glasses). Does nothing when the ray meets no screen. True when it did.
    @discardableResult func aimPointer(headYawDeg: Double, headPitchDeg: Double) -> Bool
    /// Hand tracking with a camera that faces the user (the Mac's own): puts the pointer at [u], [v] (0 to 1 from
    /// the left and from the top) of the floating screen the head is turned to, or, with no head tracking or in
    /// Steady mode, of the floating screen the pointer is already on. False with no floating screen.
    @discardableResult func placePointer(u: Double, v: Double) -> Bool
    /// Presses or lets go the mouse button where the pointer is (needs Accessibility; does nothing without it).
    func pointerButton(down: Bool)
    /// Scrolls where the pointer is, in points (needs Accessibility).
    func pointerScroll(dx: Double, dy: Double)
    /// Asks macOS for Accessibility, with its own dialog, and opens the pane in System Settings.
    func requestAccessibility()
    func openTour()
    func openSettings()
    func sendLogs()
    func saveGlassesReport()
    func exportSettings()
    func importSettings()
    func requestScreenRecording()
    func openScreenRecordingSettings()
    func openDisplaySettings()
    func restartApp()
    func quit()
    /// Gives a shortcut new keys (Carbon modifier mask, [label] as shown, such as "⌃⌥R"). Nil when it was done,
    /// else why not, in plain words.
    func changeShortcut(id: String, keyCode: UInt32, modifiers: UInt32, label: String) -> String?
    /// Puts a shortcut back to the keys it comes with ([id] nil: every shortcut).
    func resetShortcut(_ id: String?)
    /// Lets go of every shortcut while new keys are being pressed in Settings (so Pocket XR's own keys can be pressed
    /// there too), or takes them again.
    func pauseShortcuts(_ paused: Bool)
}

/// The shortcuts, in one place for the menu, the settings window and the tour to show. Each comes as Control-Option
/// and a key; the keys can be changed in Settings (ShortcutChoices).
struct Shortcut: Identifiable {
    let id: String
    let title: String
    /// The keys it comes with, as shown: "⌃⌥R".
    let usualKeys: String
    let usualKeyCode: UInt32

    /// Carbon's modifier mask (Carbon.HIToolbox): control 0x1000, option 0x0800, shift 0x0200, command 0x0100.
    static let control: UInt32 = 0x1000, option: UInt32 = 0x0800, shift: UInt32 = 0x0200, command: UInt32 = 0x0100

    init(id: String, title: String, keys: String, keyCode: UInt32) {
        self.id = id
        self.title = title
        usualKeys = keys
        usualKeyCode = keyCode
    }

    private var chosen: ShortcutChoice? { ShortcutChoices.get(id) }
    /// The keys in use now, as shown: the person's choice, else the usual ones.
    var keys: String { chosen?.label ?? usualKeys }
    var keyCode: UInt32 { chosen?.keyCode ?? usualKeyCode }
    var modifiers: UInt32 { chosen?.modifiers ?? (Shortcut.control | Shortcut.option) }
    var changed: Bool { chosen != nil }

    static let all: [Shortcut] = [
        Shortcut(id: "recentre", title: "Recentre", keys: "⌃⌥R", keyCode: 15),
        Shortcut(id: "steady", title: "Steady mode", keys: "⌃⌥S", keyCode: 1),
        Shortcut(id: "bigger", title: "Bigger", keys: "⌃⌥=", keyCode: 24),
        Shortcut(id: "smaller", title: "Smaller", keys: "⌃⌥-", keyCode: 27),
        Shortcut(id: "nearer", title: "Nearer", keys: "⌃⌥]", keyCode: 30),
        Shortcut(id: "further", title: "Further", keys: "⌃⌥[", keyCode: 33),
        Shortcut(id: "moreCurve", title: "More curve", keys: "⌃⌥.", keyCode: 47),
        Shortcut(id: "lessCurve", title: "Less curve", keys: "⌃⌥,", keyCode: 43),
        Shortcut(id: "layout", title: "Next layout", keys: "⌃⌥L", keyCode: 37),
        Shortcut(id: "depth", title: "3D on or off", keys: "⌃⌥D", keyCode: 2),
        Shortcut(id: "pointer", title: "Pointer to the screen I look at", keys: "⌃⌥P", keyCode: 35),
        Shortcut(id: "launcher", title: "Launcher", keys: "⌃⌥Space", keyCode: 49),
        Shortcut(id: "pocket", title: "Pocket mode", keys: "⌃⌥K", keyCode: 40),
        Shortcut(id: "hands", title: "Hand tracking", keys: "⌃⌥H", keyCode: 4),
    ]
}

/// One shortcut's chosen keys.
struct ShortcutChoice: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon's modifier mask.
    var modifiers: UInt32
    /// As shown, such as "⌃⌥R".
    var label: String
}

/// The keys chosen for Pocket XR's shortcuts, where they differ from the ones it comes with. Kept in UserDefaults apart
/// from the settings (which Pocket XR for Windows shares): Mac keys mean nothing on a PC. Added 17 Nov 2026 after
/// Pocket XR for Windows found shortcuts another app already held; not yet run on a Mac.
enum ShortcutChoices {
    static let key = "shortcut_keys_v1"

    static func all() -> [String: ShortcutChoice] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: ShortcutChoice].self, from: data) else { return [:] }
        return map
    }

    static func get(_ id: String) -> ShortcutChoice? { all()[id] }

    /// [choice] nil, or the usual keys, takes the shortcut back to them.
    static func set(_ id: String, _ choice: ShortcutChoice?) {
        var map = all()
        map[id] = choice
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func resetAll() { UserDefaults.standard.removeObject(forKey: key) }

    static var anyChosen: Bool { !all().isEmpty }
}

/// A key's name as Pocket XR shows it in a shortcut.
enum ShortcutKeyName {
    static func name(keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            let text: String = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return text.isEmpty ? "key \(keyCode)" : text
        }
    }

    /// The modifier symbols for Carbon's mask, in the Mac's order: ⌃⌥⇧⌘.
    static func symbols(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & Shortcut.control != 0 { text += "⌃" }
        if modifiers & Shortcut.option != 0 { text += "⌥" }
        if modifiers & Shortcut.shift != 0 { text += "⇧" }
        if modifiers & Shortcut.command != 0 { text += "⌘" }
        return text
    }
}
