import AppKit
import PocketXRCore
import SwiftUI

/// Draws the controller and Pocket mode settings, and Pocket mode's black screen, to picture files, without showing
/// a window, so the design can be looked over away from the Mac.
@MainActor
enum ControllerRender {
    /// The settings window's content width: the window's 880, less the sidebar, its hairline and the pane's margins.
    private static let sectionWidth: CGFloat = 623

    /// Renders to PNG files in `folder` at 2x: the two settings cards with a controller connected and an XREAL Aura
    /// working (controller-settings.png), and the black screen on a 1440 by 900 Mac with the button held halfway
    /// (pocket-mode.png). Returns the files written.
    static func renderAll(to folder: URL) -> [URL] {
        _ = try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = [URL]()

        let store = SettingsStore(defaults: nil)
        let state = AppState()
        state.glassesName = "XREAL Aura"
        state.glassesFamily = .aura
        state.linkOpen = true
        state.steadyAvailable = true
        state.virtualScreens = 2
        state.capturing = 2
        state.controllerName = "DualSense Wireless Controller"
        let section = ControllerSettingsSection(store: store, state: state, actions: SettingsActionsRef(nil))
            .environment(\.settingsStatic, true)
            .environment(\.colorScheme, .dark)
            .frame(width: sectionWidth)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(Color.lookPage)
        let first: URL = folder.appendingPathComponent("controller-settings.png")
        if write(section, to: first) { written.append(first) }

        let cover = PocketCoverFace(progress: 0.5, hintShown: true)
            .environment(\.colorScheme, .dark)
            .frame(width: 1440, height: 900)
        let second: URL = folder.appendingPathComponent("pocket-mode.png")
        if write(cover, to: second) { written.append(second) }
        return written
    }

    private static func write<V: View>(_ view: V, to url: URL) -> Bool {
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
}
