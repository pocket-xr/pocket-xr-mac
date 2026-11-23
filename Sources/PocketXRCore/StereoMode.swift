import Foundation

/// One display mode macOS offers for the glasses' display: its size in points, in pixels, and its refresh rate.
public struct DisplayModeInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hz: Double

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, hz: Double) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hz = hz
    }

    /// Two pictures side by side (3840 x 1080): by its pixels, as the renderer decides by its drawable's.
    public var sideBySide: Bool { GlassesOptics.isSideBySide(width: pixelWidth, height: pixelHeight) }

    public var text: String {
        let hzText = hz > 0 ? String(format: "@%.0f", hz) : ""
        return pixelWidth == width ? "\(width)x\(height)\(hzText)" : "\(width)x\(height) (\(pixelWidth)x\(pixelHeight) pixels)\(hzText)"
    }
}

/// Matching the glasses' display mode to their 2D / 3D state. When glasses switch to 3D side by side they come back
/// as a new display that offers a 3840 x 1080 mode, and they then split whatever arrives into a left and a right
/// half. Android does not pick that mode by itself, so Pocket XR on the phone asks for it (SpaceActivity's
/// askForStereoMode, 0.5.9). The Mac had relied on macOS picking it: it did with the Aura on an Intel MacBook Air, but
/// if macOS keeps the glasses at 1920 x 1080, the app draws one picture across the whole width, the glasses show its
/// left half to the left eye and its right half to the right, each stretched to twice its width, and the two run into
/// each other in the middle (a user's XREAL 1S on an M4 Pro, November 2026: "all combined in the middle").
public enum StereoMode {
    /// What to do about the glasses' display mode.
    public enum Need: Equatable, Sendable {
        /// The mode matches, or there is nothing known to match.
        case fine
        /// Switch the display to this mode (an index into the offered modes).
        case switchTo(Int)
        /// The glasses are in 3D but macOS offers no side by side mode: a 3D picture cannot be shown.
        case cannot
    }

    /// The best side by side mode among [modes]: 1:1 pixels first (not a scaled mode), then a refresh rate of 60 Hz
    /// or the nearest above it, then the most pixels. Nil when none is side by side.
    public static func pick(_ modes: [DisplayModeInfo]) -> Int? {
        let sbs = modes.indices.filter { modes[$0].sideBySide }
        func score(_ m: DisplayModeInfo) -> (Int, Double, Int) {
            let oneToOne = (m.pixelWidth == m.width || m.pixelWidth == 2 * m.width) && m.pixelWidth <= 3840 ? 1 : 0
            let hzScore = m.hz <= 0 ? -1000 : (m.hz >= 59 ? -abs(m.hz - 60) : -100 - (60 - m.hz))
            return (oneToOne, hzScore, m.pixelWidth * m.pixelHeight)
        }
        return sbs.max { a, b in
            let x = score(modes[a]), y = score(modes[b])
            if x.0 != y.0 { return x.0 < y.0 }
            if x.1 != y.1 { return x.1 < y.1 }
            return x.2 < y.2
        }
    }

    /// [glassesStereo]: the glasses' own 2D / 3D state from their control link (1 3D, 0 2D, nil not known: no link
    /// yet, or glasses without one). [want3D]: the app's 3D setting. [current]: the display's mode now.
    ///
    /// - The glasses say 3D: the display must be side by side; switch to the best such mode, or say it cannot be.
    /// - Not known, 3D wanted, and a side by side mode offered: glasses offer it only once they are in 3D, so switch.
    /// - Anything else: leave the mode alone.
    public static func need(glassesStereo: Int?, want3D: Bool, current: DisplayModeInfo?, modes: [DisplayModeInfo]) -> Need {
        if current?.sideBySide == true { return .fine }
        switch glassesStereo {
        case .some(1):
            if let i = pick(modes) { return .switchTo(i) }
            return .cannot
        case .none where want3D:
            if let i = pick(modes) { return .switchTo(i) }
            return .fine
        default:
            return .fine
        }
    }

    /// The log's list of the modes offered, the current one marked.
    public static func modesLine(_ modes: [DisplayModeInfo], current: DisplayModeInfo?) -> String {
        if modes.isEmpty { return "glasses display modes: none listed" }
        let shown = modes.map { $0.text + ($0 == current ? " (current)" : "") }
        var seen = Set<String>()
        return "glasses display modes: " + shown.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// What the Settings and the log say when the glasses are in 3D but no side by side mode is offered.
    public static let cannotNote = "3D was turned off: the glasses switched to 3D, but macOS did not offer their 3840 x 1080 "
        + "mode, so the picture would have been split wrongly. Please send logs to Mike."
}
