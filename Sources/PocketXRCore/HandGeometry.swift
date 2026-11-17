import Foundation

// Hand tracking's geometry, with no camera in it: the hand's points as the picture has them, how closed a pinch is,
// which way the palm faces, a steady point to aim through, and the camera as a pinhole. The behaviour and the
// numbers are the Android app's (core/hands: PinchDetector, PalmFacing, SteadyAnchor, HandRay), which were tuned on
// the XREAL Aura's camera with a Galaxy Z Flip 7. Nothing here has been tried on a Mac with real hands.

/// A point in the camera's picture: x to the right, y DOWN, both 0 to 1 across the frame.
public struct HandPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// From a point as Apple's Vision gives it: 0 to 1 with the origin at the LOWER left. This is the one place the
    /// picture is turned the right way up. [mirrored] also swaps left and right, for a camera that faces the person
    /// (the Mac's own, used only for testing), so that a hand moved to the right moves the pointer to the right.
    public static func fromLowerLeft(x: Double, y: Double, mirrored: Bool = false) -> HandPoint {
        HandPoint(x: mirrored ? 1 - x : x, y: 1 - y)
    }
}

public enum HandSide: String, Sendable {
    case left, right

    public var other: HandSide { self == .left ? .right : .left }
}

/// A direction as two angles in degrees: yaw to the left positive, pitch up positive (the app's own convention).
public struct HandAngles: Equatable, Sendable {
    public var yawDeg: Double
    public var pitchDeg: Double

    public static let zero = HandAngles(yawDeg: 0, pitchDeg: 0)

    public init(yawDeg: Double, pitchDeg: Double) {
        self.yawDeg = yawDeg
        self.pitchDeg = pitchDeg
    }

    public static func + (a: HandAngles, b: HandAngles) -> HandAngles {
        HandAngles(yawDeg: a.yawDeg + b.yawDeg, pitchDeg: a.pitchDeg + b.pitchDeg)
    }

    public static func - (a: HandAngles, b: HandAngles) -> HandAngles {
        HandAngles(yawDeg: a.yawDeg - b.yawDeg, pitchDeg: a.pitchDeg - b.pitchDeg)
    }

    public func scaled(_ k: Double) -> HandAngles {
        HandAngles(yawDeg: yawDeg * k, pitchDeg: pitchDeg * k)
    }

    /// How far apart two directions are, degrees (flat, which is right to a few percent for the small angles used).
    public func distance(to other: HandAngles) -> Double {
        hypot(yawDeg - other.yawDeg, pitchDeg - other.pitchDeg)
    }
}

/// The seven of a hand's 21 points that hand tracking uses, in the picture, with which hand it is when known.
public struct HandPoints: Equatable, Sendable {
    public var wrist: HandPoint
    public var thumbTip: HandPoint
    public var indexTip: HandPoint
    public var indexKnuckle: HandPoint
    public var middleKnuckle: HandPoint
    public var ringKnuckle: HandPoint
    public var littleKnuckle: HandPoint
    /// The person's own left or right hand, nil when the detector could not say.
    public var side: HandSide?
    /// The picture's width over its height (640 x 480 is 1.333), so that distances are true in both directions.
    public var aspect: Double

    public init(wrist: HandPoint, thumbTip: HandPoint, indexTip: HandPoint, indexKnuckle: HandPoint,
                middleKnuckle: HandPoint, ringKnuckle: HandPoint, littleKnuckle: HandPoint, side: HandSide?,
                aspect: Double) {
        self.wrist = wrist
        self.thumbTip = thumbTip
        self.indexTip = indexTip
        self.indexKnuckle = indexKnuckle
        self.middleKnuckle = middleKnuckle
        self.ringKnuckle = ringKnuckle
        self.littleKnuckle = littleKnuckle
        self.side = side
        self.aspect = aspect > 0 ? aspect : 1
    }

    /// From Vision's points (origin at the lower left), in this order: wrist, thumb tip, index tip, then the
    /// knuckles of the index, middle, ring and little fingers. Nil unless there are exactly seven.
    /// A mirrored picture shows a right hand as a left one, so [mirrored] swaps the side too: the palm test
    /// (HandPalm) then still answers for the camera that took the picture.
    public static func fromLowerLeft(_ points: [(x: Double, y: Double)], side: HandSide?, aspect: Double,
                                     mirrored: Bool = false) -> HandPoints? {
        guard points.count == 7 else { return nil }
        let p: [HandPoint] = points.map { HandPoint.fromLowerLeft(x: $0.x, y: $0.y, mirrored: mirrored) }
        return HandPoints(wrist: p[0], thumbTip: p[1], indexTip: p[2], indexKnuckle: p[3], middleKnuckle: p[4],
                          ringKnuckle: p[5], littleKnuckle: p[6], side: mirrored ? side?.other : side, aspect: aspect)
    }

    /// The distance between two points in units of the picture's height.
    public func distance(_ a: HandPoint, _ b: HandPoint) -> Double {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    /// Wrist to middle knuckle: a size that does not change when the fingers bend (Android: HandFrame.handSize).
    public var size: Double {
        max(distance(wrist, middleKnuckle), 1e-4)
    }

    /// Thumb tip to index tip over the hand's size, so a pinch reads the same near and far (Android:
    /// HandFrame.pinchRatio, the picture's measure). About 0.6 open, under 0.25 touching.
    public var pinchRatio: Double {
        distance(thumbTip, indexTip) / size
    }

    /// The middle of the four knuckles: where the hand is, for telling two hands apart from frame to frame.
    public var centre: HandPoint {
        HandPoint(
            x: (indexKnuckle.x + middleKnuckle.x + ringKnuckle.x + littleKnuckle.x) / 4,
            y: (indexKnuckle.y + middleKnuckle.y + ringKnuckle.y + littleKnuckle.y) / 4
        )
    }
}

/// Whether a hand shows its palm to the camera (Android: PalmFacing, 0.4.1). A right and a left hand are mirror
/// images, so which way the palm faces follows from which hand it is and the turn from the index knuckle to the
/// little finger's knuckle around the wrist.
public enum HandPalm {
    /// The sine of the angle between wrist to index knuckle and wrist to little knuckle below which the hand is
    /// seen edge on and counts neither way (Android: MIN_OPEN 0.2).
    public static let minOpen = 0.2

    /// The signed turn from the index knuckle to the little finger's knuckle around the wrist, -1 to 1, with y down:
    /// positive is clockwise on screen.
    public static func turn(_ hand: HandPoints) -> Double {
        let ax = (hand.indexKnuckle.x - hand.wrist.x) * hand.aspect
        let ay = hand.indexKnuckle.y - hand.wrist.y
        let bx = (hand.littleKnuckle.x - hand.wrist.x) * hand.aspect
        let by = hand.littleKnuckle.y - hand.wrist.y
        let length = hypot(ax, ay) * hypot(bx, by)
        if length < 1e-12 { return 0 }
        return (ax * by - ay * bx) / length
    }

    /// True when the palm faces the camera. Hold your right hand up with its palm to your face and the fingers up:
    /// the thumb and the index knuckle are on the right of the picture, the little finger on the left, which with
    /// y down is a turn against the clock (negative). A left hand is the mirror of that. (Android's rule reads the
    /// other way round only because MediaPipe names hands as a mirror would.) A hand of unknown side is never
    /// taken as showing its palm, so an unsure detector cannot open the launcher.
    public static func facesCamera(_ hand: HandPoints, minOpen: Double = minOpen) -> Bool {
        guard let side = hand.side else { return false }
        let t = turn(hand)
        return side == .right ? t < -minOpen : t > minOpen
    }
}

/// A steady point on the hand to aim through (Android: SteadyAnchor, 0.5.9). The fingertips move when a pinch
/// closes, and a pointer aimed through them would move with every click. This point is the mean of the four
/// knuckles, which do not move in a pinch (and whose mean has half one point's noise), pushed out to where a pinch
/// happens by 0.45 of the wrist to knuckles vector and 0.88 of the little to index knuckle vector. Both vectors
/// only change when the hand turns, which is slow, so they are smoothed over 250 ms.
public final class HandAnchor {
    /// Android: SteadyAnchor.FORWARD and ACROSS (Meta's stable pinch point, measured from the knuckles' mean).
    public static let forward = 0.45
    public static let across = 0.88

    public let offsetMs: Double
    private var fx = 0.0, fy = 0.0, ax = 0.0, ay = 0.0
    private var lastMs = 0.0
    private var primed = false
    private var count = 0

    public init(offsetMs: Double = 250) {
        self.offsetMs = offsetMs
    }

    /// The point for [hand] seen at [timeMs], in the picture.
    public func point(_ hand: HandPoints, timeMs: Double) -> HandPoint {
        let a = hand.aspect
        // Worked in units of the picture's height, so the vectors are true in both directions.
        let kx = hand.centre.x * a
        let ky = hand.centre.y
        let nfx = kx - hand.wrist.x * a
        let nfy = ky - hand.wrist.y
        let nax = (hand.indexKnuckle.x - hand.littleKnuckle.x) * a
        let nay = hand.indexKnuckle.y - hand.littleKnuckle.y
        if !primed || timeMs < lastMs {
            fx = nfx; fy = nfy; ax = nax; ay = nay
            primed = true
            count = 1
        } else if timeMs > lastMs {
            // A plain mean over the first frames, so the offsets start from several frames and not from one.
            count += 1
            let k = max(offsetMs <= 0 ? 1 : 1 - exp(-(timeMs - lastMs) / offsetMs), 1 / Double(count))
            fx += k * (nfx - fx); fy += k * (nfy - fy)
            ax += k * (nax - ax); ay += k * (nay - ay)
        }
        lastMs = timeMs
        let x = kx + fx * Self.forward + ax * Self.across
        let y = ky + fy * Self.forward + ay * Self.across
        return HandPoint(x: x / a, y: y)
    }

    public func reset() {
        primed = false
        count = 0
    }
}

/// The camera as a pinhole (Android: CameraModel): a point in the picture becomes a direction from the camera,
/// which sits by the eyes, so the pointer goes where the hand is seen.
public struct HandCameraModel: Equatable, Sendable {
    /// The Aura camera's width of view, degrees: its quoted 80 degrees is the diagonal of a 4:3 sensor, which is
    /// 68 across (Android: CameraModel.AURA_HFOV_DEG, 0.5.10).
    public static let auraFovDeg = 68.0
    /// For a camera that does not say and is not known: a common webcam.
    public static let unknownFovDeg = 70.0

    /// The width of view, degrees.
    public var fovDeg: Double
    /// The picture's width over its height.
    public var aspect: Double

    public init(fovDeg: Double, aspect: Double) {
        self.fovDeg = min(max(fovDeg, 10), 170)
        self.aspect = aspect > 0 ? aspect : 1
    }

    /// The height of view, degrees (square pixels).
    public var verticalFovDeg: Double {
        2 * atan(tan(fovDeg * .pi / 360) / aspect) * 180 / .pi
    }

    /// The direction the camera sees [p] in: yaw left positive, pitch up positive, 0,0 at the picture's middle.
    /// As the app turns a ray (yaw about the up axis, then pitch), so the two go together exactly.
    public func ray(_ p: HandPoint) -> HandAngles {
        let halfX = tan(fovDeg * .pi / 360)
        let halfY = halfX / aspect
        let tx = (p.x - 0.5) * 2 * halfX // to the right on a plane 1 in front
        let ty = (0.5 - p.y) * 2 * halfY // up
        let yaw = atan(-tx)
        let pitch = atan2(ty, (1 + tx * tx).squareRoot())
        return HandAngles(yawDeg: yaw * 180 / .pi, pitchDeg: pitch * 180 / .pi)
    }
}
