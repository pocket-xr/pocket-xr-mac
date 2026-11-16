import Foundation

/// What each model of glasses shows, so the Space's projection matches the real field of view (Pocket XR's
/// GlassesOptics and GlassesProfile).
public enum GlassesOptics {
    /// The Aura's vertical field per eye, degrees: the number proven on Mike's Aura with the Steam Deck port and the
    /// first Mac run (16 Nov 2026). Do not change it without a new measurement on the glasses.
    ///
    /// It differs from the Android app, which does not use one fixed number for the Aura: there the projection
    /// follows the glasses' own calibration and their Display size (4.122 by 2.319 m at 4 m at size 1.0, which is
    /// 32.3 degrees tall for a 1920 x 1080 picture, 30.8 at the 3D mode's saved 0.95), and before that XREAL's
    /// published 70 degrees diagonal on the 1920 x 1200 panels (36.9 degrees tall for a 1080 picture). The Mac does
    /// not read the glasses' Display size yet, so it keeps the proven 38.
    public static let auraFovYDeg = 38.0

    /// XREAL's published diagonal fields of view, degrees, over a 1920 x 1080 picture per eye.
    public static let oneDiagonalDeg = 50.0
    public static let oneProDiagonalDeg = 57.0 // the One Pro and the One Pro+
    public static let airDiagonalDeg = 46.0
    /// Glasses with no published figure known here (the 1S, VITURE, anything else): the One's, the nearest model
    /// the project has run on.
    public static let unknownDiagonalDeg = 50.0

    /// Wider than this (width over height) is two pictures side by side: 32:9 is 3.56, 21:9 ultrawide is 2.37.
    public static let sbsMinAspect = 3.2

    /// The vertical field of a 16:9 picture whose diagonal spans [diagonalDeg], degrees:
    /// 2 atan(tan(diagonal / 2) * 9 / sqrt(16 * 16 + 9 * 9)).
    public static func fovYDeg(diagonalDeg: Double) -> Double {
        let halfDiagonal = diagonalDeg * Double.pi / 360
        let share = 9.0 / (337.0).squareRoot()
        return 2 * atan(tan(halfDiagonal) * share) * 180 / Double.pi
    }

    /// The published diagonal field for these glasses, degrees; nil for the Aura (it has its own number) and for no
    /// glasses.
    public static func diagonalDeg(glasses: Glasses?) -> Double? {
        guard let g = glasses else { return nil }
        switch g.family {
        case .aura:
            return nil
        case .one:
            // The One Pro and One Pro+ by their USB product, else by name; the One, the 1S (not published: the
            // One's) and any other XREAL glasses taken as One family are 50.
            let name = Glasses.oneFamily[g.product] ?? g.name
            return name.contains("Pro") ? oneProDiagonalDeg : oneDiagonalDeg
        case .air:
            return airDiagonalDeg
        case .viture, .other:
            return unknownDiagonalDeg
        }
    }

    /// Each eye's vertical field of view in degrees for these glasses. The Aura: 38 (see `auraFovYDeg`). Other
    /// models: from their published diagonal field over a 16:9 picture (One 50, One Pro and Pro+ 57, Air family 46,
    /// unknown, 1S and VITURE 50 degrees). No glasses: 38. Only the Aura's has been seen on a Mac; the others are
    /// from published figures, untested.
    public static func fovYDeg(glasses: Glasses?) -> Double {
        guard let diagonal = diagonalDeg(glasses: glasses) else { return auraFovYDeg }
        return fovYDeg(diagonalDeg: diagonal)
    }

    /// Side by side when the picture is at least 3.2 times as wide as tall (the Android rule): 3840 x 1080 is, a
    /// 21:9 ultrawide is not.
    public static func isSideBySide(width: Int, height: Int) -> Bool {
        if height <= 0 { return false }
        return Double(width) / Double(height) >= sbsMinAspect
    }
}
