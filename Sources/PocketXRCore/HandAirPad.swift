import Foundation

// The air trackpad: hand tracking with a camera that FACES the person (the Mac's own), where a ray from the glasses
// makes no sense. The hand's place in the camera's picture places the pointer on the screen: a comfortable box in
// the middle of the picture stands for the whole screen. The picture is mirrored before it gets here
// (HandPoint.fromLowerLeft with mirrored), so a hand moved to the person's right is further right in it.
// Not tried with real hands yet.

/// The part of the (mirrored) picture that stands for the whole screen.
public struct HandAirBox: Equatable, Sendable {
    /// The box is the middle 60 % of the picture's width and 55 % of its height: the hand reaches every corner of
    /// the screen without leaving the picture, and a small move is not a big jump.
    public static let widthShare = 0.60
    public static let heightShare = 0.55
    /// Its middle sits a little below the picture's, so the hand can rest lower than the face.
    public static let restCentre = HandPoint(x: 0.5, y: 0.56)

    /// The gestures and the smoothing work in degrees (they were tuned on a hand ray). The box is given a
    /// screen's usual size in the glasses, 40 by 22.5 degrees, so that the same numbers mean about the same thing:
    /// a drag starts after the pointer would move 2 degrees, a twentieth of the screen's width.
    public static let widthDeg = 40.0
    public static let heightDeg = 22.5

    /// The box's middle, in the picture.
    public let centre: HandPoint

    /// [centre] is brought in so that the whole box stays inside the picture.
    public init(centre: HandPoint = HandAirBox.restCentre) {
        let halfW = Self.widthShare / 2, halfH = Self.heightShare / 2
        self.centre = HandPoint(
            x: min(max(centre.x, halfW), 1 - halfW),
            y: min(max(centre.y, halfH), 1 - halfH)
        )
    }

    public var minX: Double { centre.x - Self.widthShare / 2 }
    public var minY: Double { centre.y - Self.heightShare / 2 }

    /// Where on the screen a point of the picture stands for: u from the left, v from the top, 0 to 1 inside the
    /// box and beyond that outside it (not yet clamped, so that smoothing does not stick at the edges).
    public func place(_ p: HandPoint) -> (u: Double, v: Double) {
        (u: (p.x - minX) / Self.widthShare, v: (p.y - minY) / Self.heightShare)
    }

    /// The point of the picture that stands for [u], [v] of the screen.
    public func point(u: Double, v: Double) -> HandPoint {
        HandPoint(x: minX + u * Self.widthShare, y: minY + v * Self.heightShare)
    }

    /// A place on the screen as the angles the gestures work in: the middle is 0,0, left and up positive.
    public static func angles(u: Double, v: Double) -> HandAngles {
        HandAngles(yawDeg: (0.5 - u) * widthDeg, pitchDeg: (0.5 - v) * heightDeg)
    }

    /// Back from those angles to a place on the screen, kept on it: u and v 0 to 1.
    public static func shares(_ a: HandAngles) -> (u: Double, v: Double) {
        (u: min(max(0.5 - a.yawDeg / widthDeg, 0), 1), v: min(max(0.5 - a.pitchDeg / heightDeg, 0), 1))
    }

    /// The same without keeping it on the screen (for finding where in the picture a hand was).
    public static func openShares(_ a: HandAngles) -> (u: Double, v: Double) {
        (u: 0.5 - a.yawDeg / widthDeg, v: 0.5 - a.pitchDeg / heightDeg)
    }
}

/// Which camera hand tracking uses, as kept: the glasses' own, the Mac's built-in one, or one device by its id.
public enum HandCameraChoice: Equatable, Sendable {
    case glasses
    case mac
    case device(String)

    public init(stored: String?) {
        switch stored {
        case nil, "", "glasses": self = .glasses
        case "mac": self = .mac
        case let id?: self = .device(id)
        }
    }

    public var stored: String {
        switch self {
        case .glasses: return "glasses"
        case .mac: return "mac"
        case .device(let id): return id
        }
    }
}
