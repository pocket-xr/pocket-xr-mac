import Foundation

/// Pocket XR's look, "Light on glass", as numbers (the Android app's Look.kt): always dark, one accent, light for
/// focus and never shadow. Colours are red, green, blue, alpha, each 0 to 1.
public struct LookColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// From 0xRRGGBB, with [alpha] 0 to 1.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public func alpha(_ a: Double) -> LookColor { LookColor(r, g, b, a) }
}

public enum Look {
    public static let page = LookColor(hex: 0x0C0D10)
    public static let pad = LookColor(hex: 0x15171C)
    public static let card = LookColor(hex: 0x1A1D24)
    /// The only accent: progress, the main button, ticks, the focus halo.
    public static let accent = LookColor(hex: 0x5A93FF)
    public static let accentDeep = LookColor(hex: 0x3A6FD8)
    /// "You are holding this."
    public static let held = LookColor(hex: 0x8FB6FF)
    public static let ink = LookColor(1, 1, 1, 0.92)
    public static let ink2 = LookColor(1, 1, 1, 0.64)
    public static let ink3 = LookColor(1, 1, 1, 0.40)
    /// Hairlines.
    public static let rim = LookColor(1, 1, 1, 0.14)
    public static let rimFocus = LookColor(1, 1, 1, 0.32)
    public static let glassHover = LookColor(hex: 0x2A3142, alpha: 0.94)
    // Glass in the pictures: a gradient top to bottom, raised glass, neutral controls, a media fill.
    public static let glassTop = LookColor(hex: 0x242A39)
    public static let glassBottom = LookColor(hex: 0x181C26)
    public static let glassRaised = LookColor(hex: 0x1E2330)
    public static let control = LookColor(hex: 0x2A3142)
    public static let media = LookColor(hex: 0x2B3550)
    public static let good = LookColor(hex: 0x4CD98A)
    public static let warn = LookColor(hex: 0xF2B84B)

    // Motion: calm and exact, no overshoot anywhere. Seconds.
    public static let quick = 0.12
    public static let enter = 0.28
    public static let exit = 0.16
    public static let beat = 0.60
    /// Cubic bezier control points (x1, y1, x2, y2).
    public static let easeEnter = (0.2, 0.0, 0.0, 1.0)
    public static let easeExit = (0.3, 0.0, 1.0, 1.0)
    public static let easeInOut = (0.4, 0.0, 0.2, 1.0)
}

public extension GlowColor {
    /// The focused screen's outline colour.
    var color: LookColor {
        switch self {
        case .blue: return Look.accent
        case .white: return LookColor(1, 1, 1)
        case .purple: return LookColor(hex: 0xA77BFF)
        case .pink: return LookColor(hex: 0xFF7AB8)
        case .green: return LookColor(hex: 0x4CD98A)
        case .amber: return LookColor(hex: 0xF2B84B)
        case .red: return LookColor(hex: 0xFF6B5E)
        }
    }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public extension EdgeFade {
    /// Fade widths in pixels of a 1920 wide eye: the outer side, the inner side (toward the nose in 3D), top and bottom.
    var widths: (outer: Double, inner: Double, vertical: Double) {
        switch self {
        case .off: return (0, 0, 0)
        case .soft: return (96, 48, 48)
        case .wide: return (192, 96, 96)
        }
    }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public extension TrackingMode {
    var title: String { self == .bodyAnchor ? "Body Anchor" : "Smooth Follow" }
    var detail: String {
        self == .bodyAnchor
            ? "Screens stay where they are in the room as you turn your head."
            : "Screens drift after your head, so they are always nearly in front of you."
    }
}
