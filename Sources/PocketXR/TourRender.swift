import AppKit
import PocketXRCore
import SwiftUI

/// The tour as stills, for looking at every step without a window (and for checking a change to a picture).
@MainActor
enum TourRender {
    static let size = CGSize(width: 960, height: 640)

    /// Renders every step to PNG files in [folder] at 2x, offscreen: each step at its poster second
    /// (tour-1-welcome.png ...), three more moments of each looping step (tour-4-look-a.png ...), and Setup and Done
    /// both with nothing done (-todo) and with everything done, from sample values. Returns the files written.
    static func renderAll(to folder: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for step in Tour.steps {
            let base: String = "tour-\(step.number)-\(step.slug)"
            let poster: Double = Tour.poster(step)
            if let file = still(step, at: poster, done: true, name: base, folder: folder) { files.append(file) }
            if step == .setup || step == .done {
                if let file = still(step, at: poster, done: false, name: base + "-todo", folder: folder) { files.append(file) }
            }
            let letters: [String] = ["a", "b", "c"]
            for (i, moment) in Tour.stills(step).enumerated() where i < letters.count {
                if let file = still(step, at: moment, done: true, name: base + "-" + letters[i], folder: folder) { files.append(file) }
            }
        }
        return files
    }

    /// What the app would know with an XREAL Aura plugged in and everything allowed, or with nothing done yet.
    private static func sample(done: Bool) -> AppState {
        let state = AppState()
        if done {
            state.glassesName = "XREAL Aura"
            state.glassesFamily = .aura
            state.displayText = "3840 x 1080, 60 Hz"
            state.stereo = true
            state.trackingOn = true
            state.screenRecordingAllowed = true
            state.virtualScreens = 2
            state.capturing = 2
            state.pointerVisitedScreen = true
            state.recentred = true
        }
        return state
    }

    private static func still(_ step: TourStep, at time: Double, done: Bool, name: String, folder: URL) -> URL? {
        // Settings kept in memory only, so rendering never touches the real ones.
        let store = SettingsStore(defaults: nil)
        let state = sample(done: done)
        let model = TourModel(step: step)
        model.snap(store: store, state: state)
        let screen = TourScreen(model: model, store: store, state: state, actions: TourActionsRef(nil), fixedTime: time, reduceMotion: true, onClose: {})
            .frame(width: size.width, height: size.height)
            .background(Color.lookPage)
            .environment(\.colorScheme, ColorScheme.dark)
        let renderer = ImageRenderer(content: screen)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        guard let image = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let file = folder.appendingPathComponent(name + ".png")
        do {
            try png.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}
