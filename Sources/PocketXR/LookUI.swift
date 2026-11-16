import PocketXRCore
import SwiftUI

// Pocket XR's look for SwiftUI: the core's numbers (Look) as colours, type and motion. Shared by every window; each
// window keeps its own components in its own files.

extension LookColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

extension Color {
    static let lookPage = Look.page.color
    static let lookPad = Look.pad.color
    static let lookCard = Look.card.color
    static let lookAccent = Look.accent.color
    static let lookAccentDeep = Look.accentDeep.color
    static let lookHeld = Look.held.color
    static let lookInk = Look.ink.color
    static let lookInk2 = Look.ink2.color
    static let lookInk3 = Look.ink3.color
    static let lookRim = Look.rim.color
    static let lookRimFocus = Look.rimFocus.color
    static let lookGlassHover = Look.glassHover.color
    static let lookGood = Look.good.color
    static let lookWarn = Look.warn.color
}

extension Animation {
    /// Everything that arrives or moves on screen.
    static func lookEnter(_ duration: Double = Look.enter) -> Animation {
        .timingCurve(Look.easeEnter.0, Look.easeEnter.1, Look.easeEnter.2, Look.easeEnter.3, duration: duration)
    }

    /// Everything that leaves.
    static func lookExit(_ duration: Double = Look.exit) -> Animation {
        .timingCurve(Look.easeExit.0, Look.easeExit.1, Look.easeExit.2, Look.easeExit.3, duration: duration)
    }

    static func lookInOut(_ duration: Double = Look.enter) -> Animation {
        .timingCurve(Look.easeInOut.0, Look.easeInOut.1, Look.easeInOut.2, Look.easeInOut.3, duration: duration)
    }
}

/// The type scale (the system font, as the Mac's own apps use; the Android app's sizes).
extension Font {
    static let lookTitle = Font.system(size: 26, weight: .medium)
    static let lookHeading = Font.system(size: 16, weight: .medium)
    static let lookBody = Font.system(size: 15, weight: .regular)
    static let lookLine = Font.system(size: 14, weight: .regular)
    static let lookNote = Font.system(size: 12.5, weight: .regular)
    static let lookChip = Font.system(size: 11, weight: .regular)
    static let lookButton = Font.system(size: 14, weight: .medium)
}

/// A value of a cubic bezier easing at [t] 0...1 (for pictures drawn as a function of time).
enum LookEase {
    static func bezier(_ p: (Double, Double, Double, Double), _ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        // Solve x(s) = t for s by Newton's method, then return y(s).
        func f(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        var s = t
        for _ in 0..<8 {
            let x = f(p.0, p.2, s) - t
            let u = 1 - s
            let dx = 3 * u * u * p.0 + 6 * u * s * (p.2 - p.0) + 3 * s * s * (1 - p.2)
            if abs(dx) < 1e-6 { break }
            s = min(max(s - x / dx, 0), 1)
        }
        return f(p.1, p.3, s)
    }

    static func enter(_ t: Double) -> Double { bezier(Look.easeEnter, t) }
    static func exit(_ t: Double) -> Double { bezier(Look.easeExit, t) }
    static func inOut(_ t: Double) -> Double { bezier(Look.easeInOut, t) }
    /// Slow drift.
    static func sine(_ t: Double) -> Double { 0.5 - 0.5 * cos(.pi * min(max(t, 0), 1)) }
    /// 0 before [from], 1 after [to], linear between.
    static func span(_ t: Double, _ from: Double, _ to: Double) -> Double {
        to <= from ? (t >= to ? 1 : 0) : min(max((t - from) / (to - from), 0), 1)
    }
}
