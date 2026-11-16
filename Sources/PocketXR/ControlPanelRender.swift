import AppKit
import PocketXRCore
import SwiftUI

/// Draws the control panel to picture files, without showing a window, so the design can be looked over away from
/// the Mac.
@MainActor
enum ControlPanelRender {
    /// Renders the panel to PNG files in `folder` at 2x: as it is with an XREAL Aura and two screens
    /// (control-panel.png), in Steady mode (control-panel-steady.png), with three screens and the pointer on the
    /// Mac (control-panel-three.png), and with nothing plugged in (control-panel-empty.png). Returns the files written.
    static func renderAll(to folder: URL) -> [URL] {
        _ = try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = [URL]()

        let two: SettingsStore = sampleStore(screens: 2, layout: .row)
        let working: AppState = sampleState(store: two, pointerOn: 0)
        let first: URL = folder.appendingPathComponent("control-panel.png")
        if render(store: two, state: working, to: first) { written.append(first) }

        let steady: AppState = sampleState(store: two, pointerOn: nil)
        steady.steady = true
        steady.statusLine = "XREAL Aura · Steady mode · 60 fps"
        let second: URL = folder.appendingPathComponent("control-panel-steady.png")
        if render(store: two, state: steady, to: second) { written.append(second) }

        let three: SettingsStore = sampleStore(screens: 3, layout: .mainSide)
        let wide: AppState = sampleState(store: three, pointerOn: nil)
        let third: URL = folder.appendingPathComponent("control-panel-three.png")
        if render(store: three, state: wide, to: third) { written.append(third) }

        let fresh = SettingsStore(defaults: nil)
        let empty = AppState()
        empty.displayTiles = [DisplayTile(id: -1, title: "This Mac", frame: CGRect(x: 0, y: 0, width: 1440, height: 900))]
        let fourth: URL = folder.appendingPathComponent("control-panel-empty.png")
        if render(store: fresh, state: empty, to: fourth) { written.append(fourth) }
        return written
    }

    private static func render(store: SettingsStore, state: AppState, to url: URL) -> Bool {
        let view = ControlPanelRootView(store: store, state: state, actions: SettingsActionsRef(nil))
            .environment(\.settingsStatic, true)
            .environment(\.colorScheme, .dark)
            .frame(width: ControlPanelMetrics.width)
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

    private static func sampleStore(screens: Int, layout: ArrangeLayout) -> SettingsStore {
        let store = SettingsStore(defaults: nil)
        var s: SpaceSettings = store.s
        s.screens = screens
        s.layout = layout
        store.s = s
        return store
    }

    /// An XREAL Aura plugged in and working: tracking on, 3D, 60 frames a second, the floating screens in a row to
    /// the right of the Mac's own screen, the head turned a little to the left.
    private static func sampleState(store: SettingsStore, pointerOn: Int?) -> AppState {
        let s: SpaceSettings = store.s
        let state = AppState()
        state.glassesName = "XREAL Aura"
        state.glassesFamily = .aura
        state.displayText = "3840 x 1080, 60 Hz"
        state.stereo = true
        state.fps = 60
        state.trackingOn = true
        state.imuHz = 1000
        state.biasReady = true
        state.yawDeg = 9
        state.pitchDeg = -2
        state.linkOpen = true
        state.steadyAvailable = true
        state.screenRecordingAllowed = true
        state.virtualScreens = s.screens
        state.capturing = s.screens
        state.statusLine = "XREAL Aura · head tracking on · 3D · 60 fps"
        let aspects: [Double] = Array(repeating: 16.0 / 9.0, count: s.screens)
        state.panels = SpaceLayout.arrange(
            layout: s.layout,
            aspects: aspects,
            widthDeg: s.widthDeg,
            distance: s.distance,
            curve: s.curve
        )
        var tiles = [DisplayTile(id: -1, title: "This Mac", frame: CGRect(x: 0, y: 0, width: 1440, height: 900))]
        var x: CGFloat = 1440
        for i in 0..<s.screens {
            tiles.append(DisplayTile(id: i, title: "Screen \(i + 1)", frame: CGRect(x: x, y: 0, width: 1920, height: 1080)))
            x += 1920
        }
        state.displayTiles = tiles
        state.pointerScreen = pointerOn
        return state
    }
}
