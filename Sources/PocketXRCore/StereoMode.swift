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

    /// The highest refresh rate Pocket XR asks of a display. Above it the Mac would draw more frames than any glasses
    /// show, for nothing.
    public static let mostHz = 120.0

    /// How a refresh rate ranks: the highest up to [mostHz] first (0.5.12: it was 60 Hz first, and a developer's XREAL
    /// 1S on a Mac saw "60fps only"; Pocket XR on Android also takes the highest), anything above it after, an unknown
    /// rate last.
    static func hzRank(_ hz: Double) -> Double {
        if hz <= 0 { return -1000 }
        return hz <= mostHz + 1 ? hz : -hz
    }

    /// The best side by side mode among [modes]: 1:1 pixels first (not a scaled mode), then the highest refresh rate
    /// up to [mostHz], then the most pixels. Nil when none is side by side.
    public static func pick(_ modes: [DisplayModeInfo]) -> Int? {
        let sbs = modes.indices.filter { modes[$0].sideBySide }
        func score(_ m: DisplayModeInfo) -> (Int, Double, Int) {
            let oneToOne = (m.pixelWidth == m.width || m.pixelWidth == 2 * m.width) && m.pixelWidth <= 3840 ? 1 : 0
            return (oneToOne, hzRank(m.hz), m.pixelWidth * m.pixelHeight)
        }
        return sbs.max { a, b in
            let x = score(modes[a]), y = score(modes[b])
            if x.0 != y.0 { return x.0 < y.0 }
            if x.1 != y.1 { return x.1 < y.1 }
            return x.2 < y.2
        }
    }

    /// A mode the same size as [current] (points and pixels) with a higher refresh rate, up to [mostHz]: the fastest
    /// such one. Nil when [current] is already the fastest of its size, or not known. macOS often keeps glasses at
    /// 60 Hz when they offer 90 or 120.
    public static func faster(current: DisplayModeInfo?, modes: [DisplayModeInfo]) -> Int? {
        guard let c = current, c.hz > 0 else { return nil }
        let same = modes.indices.filter {
            let m = modes[$0]
            return m.width == c.width && m.height == c.height && m.pixelWidth == c.pixelWidth && m.pixelHeight == c.pixelHeight
                && m.hz > c.hz + 1 && m.hz <= mostHz + 1
        }
        return same.max { modes[$0].hz < modes[$1].hz }
    }

    /// The refresh rate for Pocket XR's own screens (the virtual displays the Mac's apps and pointer live on) and their
    /// capture: the fastest rate the glasses' display offers, from 60 up to [mostHz]. 0.5.11 and before made them 60 Hz
    /// whatever the glasses could show, so apps and the pointer moved at 60 frames a second on 90 and 120 Hz glasses.
    public static func screensHz(offered: [Double]) -> Int {
        let usable = offered.filter { $0 > 0 && $0 <= mostHz + 1 }
        guard let most = usable.max() else { return 60 }
        return max(60, min(Int(mostHz), Int(most.rounded())))
    }

    /// [glassesStereo]: the glasses' own 2D / 3D state from their control link (1 3D, 0 2D, nil not known: no link
    /// yet, or glasses without one). [want3D]: the app's 3D setting. [current]: the display's mode now.
    ///
    /// - The glasses say 3D: the display must be side by side; switch to the best such mode, or say it cannot be.
    /// - Not known, 3D wanted, and a side by side mode offered: glasses offer it only once they are in 3D, so switch.
    /// - Anything else: leave the mode alone.
    /// - Whatever the mode, when the same size is offered at a higher refresh rate, switch to it ([faster]).
    public static func need(glassesStereo: Int?, want3D: Bool, current: DisplayModeInfo?, modes: [DisplayModeInfo]) -> Need {
        let quicker: Need = faster(current: current, modes: modes).map { .switchTo($0) } ?? .fine
        if current?.sideBySide == true { return quicker }
        switch glassesStereo {
        case .some(1):
            if let i = pick(modes) { return .switchTo(i) }
            return .cannot
        case .none where want3D:
            if let i = pick(modes) { return .switchTo(i) }
            return quicker
        default:
            return quicker
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
