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
    /// Puts the pointer in the middle of a floating screen (its index), or of the Mac's own screen with nil.
    func movePointer(toScreen index: Int?)
    func openControlPanel()
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
}

/// The shortcuts, in one place for the menu, the settings window and the tour to show.
struct Shortcut: Identifiable {
    let id: String
    let title: String
    /// As shown: "⌃⌥R".
    let keys: String
    let keyCode: UInt32

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
    ]
}
