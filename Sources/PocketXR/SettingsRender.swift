import AppKit
import PocketXRCore
import SwiftUI

/// Draws every pane of the settings window to a picture file, without showing a window, so the design can be looked
/// over away from the Mac.
@MainActor
enum SettingsRender {
    /// Renders every pane to PNG files in `folder` (settings-space.png, ...) at 2x with sample state. A pane taller
    /// than the window is drawn whole, so nothing is hidden below a scroll. Returns the files written.
    static func renderAll(to folder: URL) -> [URL] {
        _ = try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store: SettingsStore = sampleStore()
        let state: AppState = sampleState()
        let actions = SettingsActionsRef(nil)
        var written = [URL]()
        for pane in SettingsPane.allCases {
            let url: URL = folder.appendingPathComponent("settings-\(pane.rawValue).png")
            if render(pane, store: store, state: state, actions: actions, to: url) {
                written.append(url)
            }
        }
        return written
    }

    private static func render(_ pane: SettingsPane, store: SettingsStore, state: AppState, actions: SettingsActionsRef,
                               to url: URL) -> Bool {
        let navigation = SettingsNavigation()
        navigation.pane = pane
        let size: NSSize = SettingsWindowController.defaultSize
        let view = SettingsRootView(store: store, state: state, navigation: navigation, actions: actions)
            .environment(\.settingsStatic, true)
            .environment(\.colorScheme, .dark)
            .frame(width: size.width)
            .frame(minHeight: size.height)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.lookPage)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image: CGImage = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png: Data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// The settings as they come, with two presets so the Presets card has something to show.
    private static func sampleStore() -> SettingsStore {
        let store = SettingsStore(defaults: nil)
        var s: SpaceSettings = store.s
        s.curve = 1.0
        s.presets = [
            SpacePreset(name: "Work", layout: .row, widthDeg: 40, distance: 1.4, curve: 1.0),
            SpacePreset(name: "Film", layout: .theater, widthDeg: 70, distance: 4.0, curve: 0),
        ]
        store.s = s
        return store
    }

    /// An XREAL Aura plugged in and working: tracking on, 3D, 60 frames a second.
    private static func sampleState() -> AppState {
        let state = AppState()
        state.glassesName = "XREAL Aura"
        state.glassesFamily = .aura
        state.displayText = "3840 x 1080, 60 Hz"
        state.stereo = true
        state.fps = 60
        state.trackingOn = true
        state.imuHz = 1000
        state.biasReady = true
        state.yawDeg = 12
        state.pitchDeg = -4
        state.linkOpen = true
        state.steadyAvailable = true
        state.screenRecordingAllowed = true
        state.virtualScreens = 2
        state.capturing = 2
        state.statusLine = "XREAL Aura · head tracking on · 3D"
        return state
    }
}
