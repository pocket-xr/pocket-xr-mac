import AppKit
import PocketXRCore
import SwiftUI

/// The tour's window: it hands the keys that move through the tour to the controller. Left and Right go a step back
/// and on, Return goes on (and finishes on the last step), Escape skips.
final class TourNSWindow: NSWindow {
    /// Takes a key's code; true when the tour used it.
    var onKey: ((UInt16) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .control, .option])
        if held.isEmpty, let onKey, onKey(event.keyCode) { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onKey { _ = onKey(53) }
    }
}

/// Opens the tour and keeps its window. Closing the window or finishing the tour counts as seen.
@MainActor
final class TourWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let state: AppState
    private let actions: TourActionsRef
    private let model = TourModel()
    private var window: TourNSWindow?

    init(store: SettingsStore, state: AppState, actions: AppActions) {
        self.store = store
        self.state = state
        self.actions = TourActionsRef(actions)
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func keepOnOwnScreen() { window?.keepOnOwnScreen("tour") }

    /// Shows the tour at [step]. The window is made on first use. A tour that is already open stays on the step it
    /// is on, unless a step other than the first is asked for.
    func show(step: TourStep = .welcome) {
        if isVisible {
            if step != .welcome { model.open(at: step) }
        } else {
            model.snap(store: store, state: state)
            model.arrangeTouched = false
            model.open(at: step)
        }
        let shown: TourNSWindow = window ?? makeWindow()
        window = shown
        if !shown.isVisible { shown.centre(on: NSScreen.own) }
        NSApp.activate(ignoringOtherApps: true)
        shown.makeKeyAndOrderFront(nil)
        shown.keepOnOwnScreen("tour")
        plog("tour: shown on \(shown.screen?.localizedName ?? "no screen")")
    }

    private func makeWindow() -> TourNSWindow {
        let size = NSSize(width: 960, height: 640)
        let made = TourNSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        made.title = TourCopy.windowTitle
        made.titleVisibility = .hidden
        made.titlebarAppearsTransparent = true
        made.isReleasedWhenClosed = false
        // Always dark: light on glass.
        made.appearance = NSAppearance(named: .darkAqua)
        made.backgroundColor = NSColor(srgbRed: CGFloat(Look.page.r), green: CGFloat(Look.page.g), blue: CGFloat(Look.page.b), alpha: 1)
        let root = TourScreen(model: model, store: store, state: state, actions: actions, onClose: { [weak self] in
            self?.finish()
        })
        made.contentView = NSHostingView(rootView: root)
        made.setContentSize(size)
        made.contentMinSize = NSSize(width: 860, height: 580)
        made.delegate = self
        made.onKey = { [weak self] code in
            self?.key(code) ?? false
        }
        made.center()
        return made
    }

    /// Done, Skip or Escape: the tour has been seen, and its window goes.
    private func finish() {
        store.s.tourSeen = true
        window?.close()
    }

    private func key(_ code: UInt16) -> Bool {
        guard isVisible else { return false }
        switch code {
        case 123: // Left
            model.back()
            return true
        case 124: // Right
            model.next()
            return true
        case 36, 76: // Return, Enter
            if Tour.isLast(model.step) {
                finish()
            } else {
                model.next()
            }
            return true
        case 53: // Escape
            finish()
            return true
        default:
            return false
        }
    }

    /// The red close button counts as seen. A window that closes because Pocket XR quits or starts again (it does
    /// when the glasses are plugged in) does not, so the tour comes back until the user has ended it themselves.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        store.s.tourSeen = true
        return true
    }
}
