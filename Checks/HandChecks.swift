import Foundation

// Checks for hand tracking's logic (Sources/PocketXRCore/Hand*.swift). Everything here runs without a camera: hands
// are made up as points, and the gestures are driven by the clock at 30 frames a second.

/// A hand held up with its fingers up, as the camera's picture has it (y down). [palm] true shows the palm to the
/// camera. [gap] is the thumb tip to index tip distance over the hand's size (the pinch ratio).
private func handMade(x: Double = 0.5, y: Double = 0.5, side: HandSide? = .right, palm: Bool = true, gap: Double = 0.6,
                      aspect: Double = 1) -> HandPoints {
    // A right hand showing its palm has its index knuckle (and thumb) on the right of the picture.
    let indexRight: Bool = (side != .left) == palm
    let k: Double = indexRight ? 1 : -1
    let w = 1 / aspect // so the hand is the same shape whatever the picture's shape
    let wrist = HandPoint(x: x, y: y + 0.15)
    let middle = HandPoint(x: x + k * 0.013 * w, y: y)
    let size = 0.15 // wrist to middle knuckle, near enough (the sideways 0.013 adds 0.4 %)
    let thumb = HandPoint(x: x + k * 0.08 * w, y: y - 0.05)
    let index = HandPoint(x: thumb.x, y: thumb.y - gap * size)
    return HandPoints(
        wrist: wrist, thumbTip: thumb, indexTip: index,
        indexKnuckle: HandPoint(x: x + k * 0.04 * w, y: y),
        middleKnuckle: middle,
        ringKnuckle: HandPoint(x: x - k * 0.013 * w, y: y),
        littleKnuckle: HandPoint(x: x - k * 0.04 * w, y: y),
        side: side, aspect: aspect
    )
}

private let handFrameMs = 1000.0 / 30

/// Feeds [gestures] one frame after another from [startMs] and returns each frame's events.
private func handRun(_ gestures: HandGestures, from startMs: Double, _ frames: [HandInput?]) -> [[HandEvent]] {
    var out = [[HandEvent]]()
    for (i, f) in frames.enumerated() {
        out.append(gestures.update(f, timeMs: startMs + Double(i) * handFrameMs))
    }
    return out
}

private func handFrame(_ ratio: Double, palm: Bool = false, yaw: Double = 5, pitch: Double = 2) -> HandInput {
    let aim = HandAngles(yawDeg: yaw, pitchDeg: pitch)
    return HandInput(ratio: ratio, palmFacing: palm, aim: aim, motion: aim)
}

private func handPresses(_ events: [[HandEvent]]) -> [HandAngles] {
    events.flatMap { $0 }.compactMap { e -> HandAngles? in
        if case .press(let at) = e { return at }
        return nil
    }
}

private func handCount(_ events: [[HandEvent]], _ wanted: HandEvent) -> Int {
    events.flatMap { $0 }.filter { $0 == wanted }.count
}

private func handLastAim(_ events: [HandEvent]) -> HandAngles? {
    events.compactMap { e -> HandAngles? in
        if case .aim(let a) = e { return a }
        return nil
    }.last
}

func handChecks() {
    handPointChecks()
    handFilterChecks()
    handCalibrationChecks()
    handPrimaryChecks()
    handGestureChecks()
    handAirChecks()
}

private func handAirChecks() {
    // The air trackpad's box: the middle 60 % by 55 % of the picture, resting a little low, is the whole screen.
    let box = HandAirBox()
    check(HandAirBox.widthShare == 0.60 && HandAirBox.heightShare == 0.55, "air trackpad: the box is 60 % by 55 % of the picture")
    check(box.centre == HandPoint(x: 0.5, y: 0.56), "air trackpad: the box rests a little below the middle")
    let mid = box.place(box.centre)
    check(near(mid.u, 0.5) && near(mid.v, 0.5), "air trackpad: the box's middle is the screen's middle")
    let topLeft = box.place(HandPoint(x: 0.2, y: 0.285))
    check(near(topLeft.u, 0) && near(topLeft.v, 0), "air trackpad: the box's top left is the screen's")
    let bottomRight = box.place(HandPoint(x: 0.8, y: 0.835))
    check(near(bottomRight.u, 1) && near(bottomRight.v, 1), "air trackpad: the box's bottom right is the screen's")
    let outside = box.place(HandPoint(x: 0.95, y: 0.1))
    check(outside.u > 1 && outside.v < 0, "air trackpad: outside the box is past the screen's edge until it is clamped")
    let back = box.point(u: 0.25, v: 0.75)
    let again = box.place(back)
    check(near(again.u, 0.25) && near(again.v, 0.75), "air trackpad: a place on the screen and its point in the picture go both ways")

    // Mirroring: the camera faces the person, so its picture is swapped. A hand at the person's right is on the
    // LEFT of what the camera sees (Vision's x small); mirrored, it is on the right, and so is the pointer.
    let personsRight = HandPoint.fromLowerLeft(x: 0.25, y: 0.44, mirrored: true)
    check(box.place(personsRight).u > 0.5, "air trackpad: a hand to the person's right puts the pointer right of the middle")
    let raised = HandPoint.fromLowerLeft(x: 0.5, y: 0.7, mirrored: true)
    check(box.place(raised).v < 0.5, "air trackpad: a raised hand puts the pointer above the middle")

    // A reach set off to one side keeps the whole box in the picture.
    let low = HandAirBox(centre: HandPoint(x: 0.95, y: 0.99))
    check(near(low.centre.x, 0.7) && near(low.centre.y, 0.725), "air trackpad: the box is kept inside the picture")
    check(HandAirBox(centre: HandPoint(x: 0.4, y: 0.5)).centre == HandPoint(x: 0.4, y: 0.5), "air trackpad: a reach inside the picture is taken as it is")

    // The gestures work in degrees: the screen is given 40 by 22.5 of them, left and up positive.
    check(HandAirBox.angles(u: 0.5, v: 0.5) == .zero, "air trackpad: the screen's middle is 0, 0")
    let corner = HandAirBox.angles(u: 0, v: 0)
    check(near(corner.yawDeg, 20) && near(corner.pitchDeg, 11.25), "air trackpad: the top left is left and up")
    let there = HandAirBox.shares(HandAirBox.angles(u: 0.3, v: 0.9))
    check(near(there.u, 0.3) && near(there.v, 0.9), "air trackpad: angles and back")
    let clamped = HandAirBox.shares(HandAngles(yawDeg: -50, pitchDeg: 30))
    check(clamped.u == 1 && clamped.v == 0, "air trackpad: the pointer is kept on the screen")
    let open = HandAirBox.openShares(HandAngles(yawDeg: -50, pitchDeg: 30))
    check(open.u > 1 && open.v < 0, "air trackpad: where the hand was is not clamped")

    // Which camera, as it is kept.
    check(HandCameraChoice(stored: nil) == .glasses && HandCameraChoice(stored: "") == .glasses, "hand camera: nothing kept means the glasses' camera")
    check(HandCameraChoice(stored: "mac") == .mac && HandCameraChoice(stored: "glasses") == .glasses, "hand camera: the two named choices")
    check(HandCameraChoice(stored: "0x1420000005ac8514") == .device("0x1420000005ac8514"), "hand camera: anything else is one device's id")
    check(HandCameraChoice(stored: HandCameraChoice.device("abc").stored) == .device("abc") && HandCameraChoice.mac.stored == "mac", "hand camera: kept and read back")
}

private func handPointChecks() {
    // Vision's origin is the lower left; ours is the upper left. The flip is in one place.
    let flipped = HandPoint.fromLowerLeft(x: 0.2, y: 0.9)
    check(near(flipped.x, 0.2) && near(flipped.y, 0.1), "hands: a point from Vision is turned the right way up")
    let mirrored = HandPoint.fromLowerLeft(x: 0.2, y: 0.9, mirrored: true)
    check(near(mirrored.x, 0.8) && near(mirrored.y, 0.1), "hands: a mirrored point also swaps left and right")

    // A right hand, palm to the camera, as Vision would give it (y up): wrist low, index knuckle to the right.
    let vision: [(x: Double, y: Double)] = [
        (0.50, 0.35), (0.58, 0.55), (0.58, 0.64), (0.54, 0.50), (0.513, 0.50), (0.487, 0.50), (0.46, 0.50),
    ]
    let seen = HandPoints.fromLowerLeft(vision, side: .right, aspect: 4.0 / 3)
    check(seen != nil, "hands: seven points make a hand")
    check(HandPoints.fromLowerLeft(Array(vision.dropLast()), side: .right, aspect: 1) == nil, "hands: six points do not")
    if let seen {
        check(near(seen.wrist.y, 0.65) && near(seen.indexKnuckle.y, 0.5), "hands: the wrist is below the knuckles after the flip")
        check(seen.wrist.y > seen.indexTip.y, "hands: fingers up means a smaller y")
        check(HandPalm.facesCamera(seen), "hands: a right hand from Vision with its index knuckle on the right shows its palm")
    }
    // Mirrored (the Mac's own camera): the picture is swapped and the hand's side with it, so the answer for the
    // camera stays the same.
    if let swapped = HandPoints.fromLowerLeft(vision, side: .right, aspect: 4.0 / 3, mirrored: true) {
        check(swapped.side == .left, "hands: a mirrored right hand is handled as a left one")
        check(near(swapped.indexKnuckle.x, 0.46), "hands: a mirrored hand's points are swapped left to right")
        check(HandPalm.facesCamera(swapped), "hands: mirroring does not change whether the palm faces the camera")
    }

    // Palm facing: each hand, each way, edge on, and a hand of unknown side.
    check(HandPalm.facesCamera(handMade(side: .right, palm: true)), "hands: right palm faces the camera")
    check(!HandPalm.facesCamera(handMade(side: .right, palm: false)), "hands: the back of a right hand does not")
    check(HandPalm.facesCamera(handMade(side: .left, palm: true)), "hands: left palm faces the camera")
    check(!HandPalm.facesCamera(handMade(side: .left, palm: false)), "hands: the back of a left hand does not")
    check(HandPalm.turn(handMade(side: .right, palm: true)) < -HandPalm.minOpen, "hands: a right palm turns against the clock with y down")
    var unknown = handMade(side: .right, palm: true)
    unknown.side = nil
    check(!HandPalm.facesCamera(unknown), "hands: a hand of unknown side never counts as a palm")
    var edge = handMade(side: .right, palm: true)
    edge.indexKnuckle = HandPoint(x: 0.501, y: 0.5)
    edge.littleKnuckle = HandPoint(x: 0.499, y: 0.5)
    check(!HandPalm.facesCamera(edge), "hands: a hand seen edge on counts neither way")
    check(HandPalm.facesCamera(handMade(side: .right, palm: true, aspect: 16.0 / 9)), "hands: the palm test holds in a wide picture")

    // The pinch measure is the same whatever the picture's shape, near or far.
    check(near(handMade(gap: 0.6).pinchRatio, 0.6, 0.01), "hands: an open hand reads about 0.6")
    check(near(handMade(gap: 0.2, aspect: 16.0 / 9).pinchRatio, 0.2, 0.01), "hands: a pinch reads the same in a wide picture")
    var sideways = handMade(gap: 0.6, aspect: 2)
    sideways.thumbTip = HandPoint(x: 0.5, y: 0.4)
    sideways.indexTip = HandPoint(x: 0.55, y: 0.4)
    // 0.05 of the width in a picture twice as wide as high is 0.1 of its height.
    check(near(sideways.distance(sideways.thumbTip, sideways.indexTip), 0.1), "hands: sideways distances are scaled by the picture's shape")

    // The steady point: knuckles' mean + 0.45 of wrist to knuckles + 0.88 of little to index knuckle.
    let anchor = HandAnchor()
    let open = handMade(gap: 0.6)
    let first = anchor.point(open, timeMs: 0)
    check(near(first.x, 0.5 + 0.88 * 0.08, 1e-9) && near(first.y, 0.5 - 0.45 * 0.15, 1e-9), "hands: the steady point is where a pinch happens")
    let closed = handMade(gap: 0.05)
    let second = anchor.point(closed, timeMs: handFrameMs)
    check(near(first.x, second.x, 1e-9) && near(first.y, second.y, 1e-9), "hands: closing the fingers does not move the steady point")
    var moved = open
    for keyPath in [\HandPoints.wrist, \HandPoints.indexKnuckle, \HandPoints.middleKnuckle, \HandPoints.ringKnuckle, \HandPoints.littleKnuckle] {
        moved[keyPath: keyPath].x += 0.1
    }
    let third = anchor.point(moved, timeMs: 2 * handFrameMs)
    check(near(third.x - first.x, 0.1, 1e-9), "hands: moving the hand moves the steady point as far")
    // A sudden turn of the hand (the knuckles swapped over) comes through smoothed, not at once.
    let turnAnchor = HandAnchor()
    _ = turnAnchor.point(handMade(palm: true), timeMs: 0)
    _ = turnAnchor.point(handMade(palm: true), timeMs: 33)
    _ = turnAnchor.point(handMade(palm: true), timeMs: 66)
    let turned = turnAnchor.point(handMade(palm: false), timeMs: 99)
    check(turned.x > 0.5 && turned.x < first.x, "hands: the steady point's offsets are smoothed when the hand turns")
    turnAnchor.reset()
    let afresh = turnAnchor.point(handMade(palm: false), timeMs: 132)
    check(near(afresh.x, 0.5 - 0.88 * 0.08, 1e-9), "hands: after a reset the steady point starts from the frame it is given")

    // The pinhole: the middle is straight ahead, the edges are half the field of view out, left and up positive.
    let camera = HandCameraModel(fovDeg: 68, aspect: 16.0 / 9)
    check(near(camera.verticalFovDeg, 41.6, 0.1), "hands: 68 degrees across a 16:9 picture is 41.6 up and down")
    let middle = camera.ray(HandPoint(x: 0.5, y: 0.5))
    check(near(middle.yawDeg, 0) && near(middle.pitchDeg, 0), "hands: the picture's middle is straight ahead")
    check(near(camera.ray(HandPoint(x: 1, y: 0.5)).yawDeg, -34), "hands: the right edge is half the view to the right (negative)")
    check(near(camera.ray(HandPoint(x: 0, y: 0.5)).yawDeg, 34), "hands: the left edge is half the view to the left")
    check(near(camera.ray(HandPoint(x: 0.5, y: 0)).pitchDeg, camera.verticalFovDeg / 2), "hands: the top edge is half the view up")
    check(camera.ray(HandPoint(x: 0.5, y: 1)).pitchDeg < 0, "hands: the bottom is down")
    // A corner, taken back through the app's own turn (yaw about up, then pitch): it must land on the same point.
    let corner = HandPoint(x: 0.9, y: 0.2)
    let ray = camera.ray(corner)
    let yaw = ray.yawDeg * .pi / 180, pitch = ray.pitchDeg * .pi / 180
    let dx = -sin(yaw) * cos(pitch), dy = sin(pitch), dz = -cos(yaw) * cos(pitch)
    let halfX = tan(34 * Double.pi / 180)
    let backX = 0.5 + (dx / -dz) / (2 * halfX)
    let backY = 0.5 - (dy / -dz) / (2 * halfX / (16.0 / 9))
    check(near(backX, corner.x, 1e-9) && near(backY, corner.y, 1e-9), "hands: a ray's angles are the app's own (yaw, then pitch)")
    check(HandCameraModel(fovDeg: 500, aspect: 0).fovDeg == 170, "hands: an absurd field of view is brought into range")
}

private func handFilterChecks() {
    // The pinch detector: 2 frames below 0.25, or 1 below 0.15; out only after 2 frames above 0.42.
    let d = HandPinchDetector()
    let steps: [(Double, Bool)] = [(0.6, false), (0.24, false), (0.3, false), (0.24, false), (0.24, true)]
    for (i, s) in steps.enumerated() {
        check(d.update(s.0) == s.1, "hands: pinch detector step \(i) at \(s.0)")
    }
    for (i, s) in [(0.3, true), (0.41, true), (0.5, true), (0.3, true), (0.5, true), (0.5, false)].enumerated() {
        check(d.update(s.0) == s.1, "hands: pinch release step \(i) at \(s.0)")
    }
    check(d.update(0.14), "hands: fingers clearly touching pinch on the first frame")
    d.reset()
    check(!d.pinched, "hands: a reset pinch detector is open")
    check(!d.update(0.2) && d.update(0.2), "hands: after a reset it needs its two frames again")

    // One Euro: a still value stays, jitter is cut, a sweep is followed closely, time must move forward.
    let still = HandOneEuro()
    var out = 0.0
    for i in 0..<60 { out = still.filter(5, timeMs: Double(i) * handFrameMs) }
    check(near(out, 5), "hands: a still value stays where it is")
    let noisy = HandOneEuro()
    var low = Double.infinity, high = -Double.infinity
    for i in 0..<120 {
        let v = noisy.filter(10 + (i % 2 == 0 ? 0.15 : -0.15), timeMs: Double(i) * handFrameMs)
        if i >= 60 { low = min(low, v); high = max(high, v) }
    }
    check(high - low < 0.06, "hands: 0.3 degrees of jitter comes out under 0.06 (got \(high - low))")
    check(abs((high + low) / 2 - 10) < 0.02, "hands: jitter does not shift the value")
    let sweep = HandOneEuro()
    var lag = 0.0
    for i in 0..<30 {
        let x = 2.0 * Double(i) // 60 degrees a second
        lag = x - sweep.filter(x, timeMs: Double(i) * handFrameMs)
    }
    check(lag >= 0 && lag < 0.5, "hands: a 60 degrees a second sweep lags under half a degree (got \(lag))")
    let stuck = HandOneEuro()
    _ = stuck.filter(1, timeMs: 100)
    check(near(stuck.filter(9, timeMs: 100), 1) && near(stuck.filter(9, timeMs: 50), 1), "hands: a frame whose time has not moved on changes nothing")
    stuck.reset()
    check(near(stuck.filter(9, timeMs: 10), 9), "hands: a reset filter starts from the value it is given")
    let both = HandRayFilter()
    _ = both.filter(HandAngles(yawDeg: 0, pitchDeg: 3), timeMs: 0)
    var swept = HandAngles.zero
    for i in 1..<30 { swept = both.filter(HandAngles(yawDeg: 2.0 * Double(i), pitchDeg: 3), timeMs: Double(i) * handFrameMs) }
    check(near(swept.pitchDeg, 3) && swept.yawDeg > 57, "hands: a sideways sweep leaves the pitch still")
}

private func handCalibrationChecks() {
    let rays: [HandAngles] = [
        HandAngles(yawDeg: 0, pitchDeg: 0), HandAngles(yawDeg: 12, pitchDeg: 7), HandAngles(yawDeg: -12, pitchDeg: 7),
        HandAngles(yawDeg: -12, pitchDeg: -7), HandAngles(yawDeg: 12, pitchDeg: -7),
    ]
    let truth = HandCalibration(a: 1.1, b: 0.05, c: 2, d: -0.03, e: 0.9, f: -1.5)
    let wanted: [HandAngles] = rays.map { truth.apply($0) }
    let fit = HandCalibration.fit(measured: rays, wanted: wanted)
    let close = zip(fit.numbers, truth.numbers).allSatisfy { near($0, $1, 1e-6) }
    check(close, "hand calibration: five dots give back the correction that made them")
    check(fit.rmsDeg(measured: rays, wanted: wanted) < 1e-6, "hand calibration: an exact fit is 0 degrees off")
    let applied = truth.apply(HandAngles(yawDeg: 10, pitchDeg: 4))
    check(near(applied.yawDeg, 1.1 * 10 + 0.05 * 4 + 2) && near(applied.pitchDeg, -0.03 * 10 + 0.9 * 4 - 1.5), "hand calibration: apply is the two lines")
    check(HandCalibration.identity.apply(HandAngles(yawDeg: 3, pitchDeg: -4)) == HandAngles(yawDeg: 3, pitchDeg: -4), "hand calibration: none changes nothing")
    check(HandCalibration.fit(measured: [], wanted: []).isIdentity, "hand calibration: no dots, no correction")

    // One or two dots: only the offset.
    let two = HandCalibration.fit(measured: Array(rays.prefix(2)), wanted: Array(wanted.prefix(2)))
    check(two.a == 1 && two.e == 1 && two.b == 0 && two.d == 0, "hand calibration: two dots give an offset only")
    let meanYaw = ((wanted[0].yawDeg - rays[0].yawDeg) + (wanted[1].yawDeg - rays[1].yawDeg)) / 2
    check(near(two.c, meanYaw), "hand calibration: the offset is the mean difference")

    // A fit no camera could give (a pinch on the wrong dot) falls back to the offset.
    let wild: [HandAngles] = rays.map { HandAngles(yawDeg: 2.5 * $0.yawDeg + 1, pitchDeg: $0.pitchDeg) }
    let fallback = HandCalibration.fit(measured: rays, wanted: wild)
    check(fallback.a == 1 && near(fallback.c, 1), "hand calibration: a gain of 2.5 is refused and the offset kept")
    check(fallback.rmsDeg(measured: rays, wanted: wild) > HandCalibration.maxRmsDeg, "hand calibration: and it reads as too far off")
    // Dots in a line cannot pin the fit down.
    let line: [HandAngles] = [HandAngles(yawDeg: -10, pitchDeg: 0), HandAngles(yawDeg: 0, pitchDeg: 0), HandAngles(yawDeg: 10, pitchDeg: 0)]
    let flat = HandCalibration.fit(measured: line, wanted: line.map { $0 + HandAngles(yawDeg: 1, pitchDeg: 2) })
    check(flat.a == 1 && near(flat.c, 1) && near(flat.f, 2), "hand calibration: dots in a line give an offset only")

    // Kept as six numbers.
    check(HandCalibration(numbers: truth.numbers) == truth, "hand calibration: six numbers and back")
    check(HandCalibration(numbers: [1, 0, 0, 0, 1]) == nil, "hand calibration: five numbers are not one")
    check(HandCalibration(numbers: [1, 0, .nan, 0, 1, 0]) == nil, "hand calibration: a number that is not one is refused")

    // Where a dot is, from the screen's place in the Space and the head's turn.
    let panel = PanelPlacement(yawDeg: 21, pitchDeg: 0, widthDeg: 40, aspect: 16.0 / 9, distance: 1.4)
    let centre = HandCalibrationRun.target(panel: panel, u: 0.5, v: 0.5, headYawDeg: 9, headPitchDeg: -2)
    check(near(centre.yawDeg, 12) && near(centre.pitchDeg, 2), "hand calibration: the middle dot is the screen's middle less the head's turn")
    let corner = HandCalibrationRun.target(panel: panel, u: 0.2, v: 0.2, headYawDeg: 9, headPitchDeg: -2)
    check(near(corner.yawDeg, 12 + 0.3 * 40) && near(corner.pitchDeg, 2 + 0.3 * panel.heightDeg), "hand calibration: the upper left dot is to the left and up")

    // A run: the middle, then four corners 20 % in; five pinches and it is done.
    check(HandCalibrationRun.dots.count == 5, "hand calibration: five dots")
    check(HandCalibrationRun.dots[0].u == 0.5 && HandCalibrationRun.dots[0].v == 0.5, "hand calibration: the middle first")
    check(HandCalibrationRun.dots.dropFirst().allSatisfy { [0.2, 0.8].contains($0.u) && [0.2, 0.8].contains($0.v) }, "hand calibration: then corners 20 % in")
    var run = HandCalibrationRun()
    check(run.step == 0 && !run.done && !run.result().ok, "hand calibration: a run starts at the first dot with nothing to keep")
    for (i, dot) in HandCalibrationRun.dots.enumerated() {
        check(run.dot.map { $0.u == dot.u && $0.v == dot.v } ?? false, "hand calibration: dot \(i + 1) in its turn")
        let target = HandCalibrationRun.target(panel: panel, u: dot.u, v: dot.v, headYawDeg: 9, headPitchDeg: -2)
        // A camera that points 3 degrees right and 2 down of where the pinhole guess has it.
        run.record(ray: target + HandAngles(yawDeg: 3, pitchDeg: 2), target: target)
    }
    check(run.done && run.dot == nil && run.step == 5, "hand calibration: five pinches finish the run")
    let result = run.result()
    check(result.ok && result.rmsDeg < 1e-6, "hand calibration: a steady camera error is taken up whole")
    check(near(result.calibration.c, -3, 1e-6) && near(result.calibration.f, -2, 1e-6), "hand calibration: 3 right and 2 down are taken off")
    run.record(ray: .zero, target: .zero)
    check(run.step == 5, "hand calibration: a sixth pinch is not counted")
}

private func handPrimaryChecks() {
    let a = HandPoint(x: 0.3, y: 0.5), b = HandPoint(x: 0.7, y: 0.5)
    let p = HandPrimary()
    check(p.choose([], timeMs: 0) == nil, "hands: no hands, no pointer hand")
    check(p.choose([a], timeMs: 0) == 0, "hands: the first hand seen has the pointer")
    check(p.choose([b, HandPoint(x: 0.31, y: 0.5)], timeMs: 33) == 1, "hands: it keeps the pointer when a second hand comes, whatever the order")
    check(p.choose([b], timeMs: 66) == nil, "hands: the second hand alone is not given the pointer")
    check(p.choose([b], timeMs: 400) == nil, "hands: not while the first has been gone under 500 ms")
    check(p.choose([HandPoint(x: 0.33, y: 0.52), b], timeMs: 433) == 0, "hands: the first hand back takes up where it left off")
    check(p.choose([b], timeMs: 466) == nil, "hands: and is lost again")
    check(p.choose([b], timeMs: 940) == 0, "hands: after 500 ms without it the other hand takes the pointer")
    check(p.choose([a, HandPoint(x: 0.69, y: 0.5)], timeMs: 973) == 1, "hands: and keeps it when the first comes back")

    // One hand moving fast is still the same hand.
    let q = HandPrimary()
    _ = q.choose([a], timeMs: 0)
    check(q.choose([HandPoint(x: 0.6, y: 0.4)], timeMs: 33) == 0, "hands: a lone hand that jumps is still the pointer's hand")
    check(q.choose([], timeMs: 66) == nil && q.choose([b], timeMs: 99) == 0, "hands: a lone hand back after a dropped frame keeps the pointer")
    q.reset()
    check(q.choose([b, a], timeMs: 200) == 0, "hands: after a reset the first listed hand takes the pointer")
}

private func handGestureChecks() {
    // Aiming: every frame of an open hand aims the pointer where the hand does.
    let aimG = HandGestures()
    let aiming = handRun(aimG, from: 0, [handFrame(0.6), handFrame(0.6, yaw: 6), handFrame(0.62, yaw: 7)])
    check(aiming.map { $0.count } == [1, 1, 1], "hand gestures: one aim a frame")
    check(handLastAim(aiming[2]) == HandAngles(yawDeg: 7, pitchDeg: 2), "hand gestures: the aim is the hand's")

    // A tap: the fingers close while the hand drifts. The aim is locked where it was before they began to close,
    // the press lands there, and nothing moves until they open.
    let tapG = HandGestures()
    var frames: [HandInput?] = Array(repeating: handFrame(0.6), count: 10)
    frames += [handFrame(0.40, yaw: 5.3, pitch: 1.8), handFrame(0.20, yaw: 5.6, pitch: 1.6), handFrame(0.10, yaw: 5.8, pitch: 1.5)]
    frames += [handFrame(0.10, yaw: 5.8, pitch: 1.5), handFrame(0.50, yaw: 5.7, pitch: 1.5), handFrame(0.60, yaw: 5.6, pitch: 1.6)]
    let tap = handRun(tapG, from: 0, frames)
    let rest = HandAngles(yawDeg: 5, pitchDeg: 2)
    check(tap[10] == [.aim(rest)], "hand gestures: the aim locks as the fingers start to close (got \(tap[10]))")
    check(tap[11].isEmpty, "hand gestures: a locked aim does not follow the hand")
    check(tap[12] == [.aim(rest), .press(rest)], "hand gestures: the press lands where the aim was before the pinch (got \(tap[12]))")
    check(tap[13].isEmpty && tap[14].isEmpty, "hand gestures: a held pinch does not move the pointer, and one open frame does not let go")
    check(tap[15] == [.release], "hand gestures: two open frames let go")
    check(handPresses(tap).count == 1 && handCount(tap, .release) == 1, "hand gestures: a tap is one press and one release")
    check(tapG.phase == .idle, "hand gestures: back to aiming after a tap")
    // Afterwards the pointer glides from the locked spot onto the hand; it does not jump.
    let after = handRun(tapG, from: 16 * handFrameMs, Array(repeating: handFrame(0.6, yaw: 5.6, pitch: 1.6), count: 12))
    let firstAfter = handLastAim(after[0]) ?? .zero
    let lastAfter = handLastAim(after[11]) ?? .zero
    check(firstAfter.distance(to: rest) < 0.5, "hand gestures: the first aim after a tap is still near the locked spot")
    check(lastAfter.distance(to: HandAngles(yawDeg: 5.6, pitchDeg: 1.6)) < 0.02, "hand gestures: and it ends on the hand")

    // A drag: pinched, held 250 ms and moved 2 degrees. The pointer then follows the hand from the locked spot.
    let dragG = HandGestures()
    var drag: [HandInput?] = Array(repeating: handFrame(0.6), count: 6)
    drag.append(handFrame(0.10)) // touching: pinched at once
    for i in 1...12 { drag.append(handFrame(0.10, yaw: 5 + 0.5 * Double(i))) }
    drag += [handFrame(0.6, yaw: 11), handFrame(0.6, yaw: 11)]
    let dragged = handRun(dragG, from: 0, drag)
    check(dragged[6] == [.aim(rest), .press(rest)], "hand gestures: a quick pinch presses where the hand aimed")
    check((7...13).allSatisfy { dragged[$0].isEmpty }, "hand gestures: under 250 ms a moving pinch is not yet a drag")
    check(dragged[14] == [.aim(rest)], "hand gestures: the drag starts from the pressed spot (got \(dragged[14]))")
    // Frame 14 is 8 frames after the press (4 degrees on); each frame after it moves the pointer 0.5 further.
    check(dragged[15] == [.aim(HandAngles(yawDeg: 5.5, pitchDeg: 2))], "hand gestures: a drag follows the hand, one for one")
    check(dragged[18] == [.aim(HandAngles(yawDeg: 7, pitchDeg: 2))], "hand gestures: and keeps following")
    check(dragged[19].count == 1 && dragged[20].last == .release, "hand gestures: opening the fingers drops it")
    check(handPresses(dragged).count == 1 && handCount(dragged, .release) == 1, "hand gestures: a drag is one press and one release")

    // A big move at once is a drag whatever the clock says.
    let farG = HandGestures()
    let far = handRun(farG, from: 0, [handFrame(0.6), handFrame(0.6), handFrame(0.1), handFrame(0.1, yaw: 12)])
    check(far[3] == [.aim(rest)] && farG.phase == .dragging, "hand gestures: 6 degrees at once is a drag")

    // Palm, then a short pinch: the launcher, and never a click.
    let palmG = HandGestures()
    var palm: [HandInput?] = Array(repeating: handFrame(0.6, palm: true), count: 8) // 233 ms facing
    palm += [handFrame(0.1, palm: true), handFrame(0.1, palm: true), handFrame(0.6, palm: true), handFrame(0.6, palm: true)]
    let palmed = handRun(palmG, from: 0, palm)
    check(palmG.phase == .idle && handCount(palmed, .toggleLauncher) == 1, "hand gestures: palm then a short pinch toggles the launcher")
    check(palmed[11] == [.toggleLauncher], "hand gestures: the launcher toggles as the fingers open")
    check(handPresses(palmed).isEmpty && handCount(palmed, .release) == 0, "hand gestures: a palm pinch never clicks")
    check(palmed[8].isEmpty && palmed[9].isEmpty, "hand gestures: the pointer is held during a palm pinch")

    // The same pinch held 650 ms: recentre, once, and no launcher on letting go.
    let holdG = HandGestures()
    var hold: [HandInput?] = Array(repeating: handFrame(0.6, palm: true), count: 8)
    hold += Array(repeating: handFrame(0.1, palm: true), count: 24) // 800 ms
    hold += [handFrame(0.6, palm: true), handFrame(0.6, palm: true)]
    let held = handRun(holdG, from: 0, hold)
    check(handCount(held, .recentre) == 1 && handCount(held, .toggleLauncher) == 0, "hand gestures: a palm pinch held recentres and does not toggle the launcher")
    let recentredAt = held.firstIndex { $0.contains(.recentre) } ?? -1
    // Pinched at frame 8; 650 ms later is 19.5 frames on.
    check(recentredAt == 28, "hand gestures: recentre comes at 650 ms (frame \(recentredAt))")
    check(handPresses(held).isEmpty, "hand gestures: a held palm pinch never clicks")

    // A palm only just turned (under 200 ms) does not count: the pinch is a click.
    let briefG = HandGestures()
    var brief: [HandInput?] = Array(repeating: handFrame(0.6), count: 6)
    brief += Array(repeating: handFrame(0.6, palm: true), count: 4) // 100 ms facing
    brief += [handFrame(0.1, palm: true)]
    let briefly = handRun(briefG, from: 0, brief)
    check(handPresses(briefly).count == 1, "hand gestures: a palm turned for under 200 ms pinches as a click")
    check(!HandGestures().palmReady(timeMs: 0), "hand gestures: no palm, not ready")

    // A hand that turns its palm away loses the palm's 200 ms.
    let awayG = HandGestures()
    var away: [HandInput?] = Array(repeating: handFrame(0.6, palm: true), count: 8)
    away += [handFrame(0.6, palm: false), handFrame(0.6, palm: true), handFrame(0.1, palm: true)]
    check(handPresses(handRun(awayG, from: 0, away)).count == 1, "hand gestures: the palm's 200 ms start again after it turns away")

    // The hand lost while pinched: held through a short gap, let go at 500 ms, then quiet.
    let lostG = HandGestures()
    var lost: [HandInput?] = [handFrame(0.6), handFrame(0.6), handFrame(0.1)]
    lost += Array(repeating: nil, count: 20)
    let gone = handRun(lostG, from: 0, lost)
    check((3...16).allSatisfy { gone[$0].isEmpty }, "hand gestures: a pinch is held through a gap under 500 ms")
    // Last seen at frame 2; 500 ms later is frame 17.
    check(gone[17] == [.release, .handLost], "hand gestures: a lost hand lets go at 500 ms (got \(gone[17]))")
    check((18...22).allSatisfy { gone[$0].isEmpty }, "hand gestures: and says so once")
    check(lostG.phase == .idle, "hand gestures: a lost hand starts afresh")
    let backG = HandGestures()
    var back: [HandInput?] = [handFrame(0.6), handFrame(0.6), handFrame(0.1)]
    back += Array(repeating: nil, count: 6) // 200 ms gap
    back += [handFrame(0.1), handFrame(0.6), handFrame(0.6)]
    let returned = handRun(backG, from: 0, back)
    check(handPresses(returned).count == 1 && returned[11] == [.release], "hand gestures: a pinch survives dropped frames and ends when the fingers open")
    let idleG = HandGestures()
    var idle: [HandInput?] = [handFrame(0.6)]
    idle += Array(repeating: nil, count: 18)
    check(handRun(idleG, from: 0, idle).flatMap { $0 }.filter { $0 != .aim(rest) } == [.handLost], "hand gestures: an open hand lost is lost without a release")
    check(HandGestures().update(nil, timeMs: 5000).isEmpty, "hand gestures: no hand yet, nothing to do")

    // A lock that never becomes a pinch lets go when the fingers reopen, and the pointer glides on.
    let abortG = HandGestures()
    var abort: [HandInput?] = Array(repeating: handFrame(0.6), count: 6)
    abort += [handFrame(0.40), handFrame(0.40, yaw: 5.2), handFrame(0.55, yaw: 5.4), handFrame(0.6, yaw: 5.4)]
    let aborted = handRun(abortG, from: 0, abort)
    check(aborted[6] == [.aim(rest)] && aborted[7].isEmpty, "hand gestures: half closed fingers lock the aim")
    check(abortG.phase == .idle && handPresses(aborted).isEmpty, "hand gestures: reopened fingers end the lock without a click")
    check((handLastAim(aborted[9]) ?? .zero).distance(to: rest) < 0.4, "hand gestures: and the pointer starts again from the locked spot")

    // A hand that moves on half closed is aiming: the lock lets go after 250 ms and 2.5 degrees.
    let moveG = HandGestures()
    var move: [HandInput?] = Array(repeating: handFrame(0.6), count: 6)
    move.append(handFrame(0.40))
    for i in 1...12 { move.append(handFrame(0.40, yaw: 5 + 0.5 * Double(i))) }
    let movedOn = handRun(moveG, from: 0, move)
    check(moveG.phase == .idle, "hand gestures: a half closed hand that moves on is let go")
    check((7...13).allSatisfy { movedOn[$0].isEmpty } && !movedOn[15].isEmpty, "hand gestures: after 250 ms, not before")

    // A resting half closed hand cannot hold the pointer for ever.
    let restG = HandGestures()
    var resting: [HandInput?] = Array(repeating: handFrame(0.6), count: 6)
    resting += Array(repeating: handFrame(0.40), count: 32) // over 900 ms
    let rested = handRun(restG, from: 0, resting)
    check(restG.phase == .idle && rested.last?.count == 1, "hand gestures: a lock lets go after 900 ms")

    // When the head aims (look and pinch) the aim is always straight ahead and a drag is measured on the head.
    let lookG = HandGestures()
    func look(_ ratio: Double, head: Double) -> HandInput {
        HandInput(ratio: ratio, palmFacing: false, aim: .zero, motion: HandAngles(yawDeg: head, pitchDeg: 0))
    }
    var looking: [HandInput?] = [look(0.6, head: 0), look(0.6, head: 0), look(0.1, head: 0)]
    for i in 1...10 { looking.append(look(0.1, head: Double(i))) }
    let looked = handRun(lookG, from: 0, looking)
    check(looked[2] == [.aim(.zero), .press(.zero)], "hand gestures: with the head aiming, a pinch presses straight ahead")
    check(lookG.phase == .dragging, "hand gestures: turning the head while pinched is a drag")
    check(looked.flatMap { $0 }.allSatisfy { e in
        if case .aim(let a) = e { return a == .zero }
        return true
    }, "hand gestures: with the head aiming, every aim is straight ahead")
    check(!HandGestures().holdsPointer, "hand gestures: an idle hand does not hold the pointer")

    // Started afresh with the fingers closed (a calibration's last pinch): nothing until they have opened, then
    // pinches count again.
    let freshG = HandGestures()
    freshG.reset(waitForOpen: true)
    var fresh: [HandInput?] = Array(repeating: handFrame(0.1), count: 6)
    let closedStill = handRun(freshG, from: 0, fresh)
    check(handPresses(closedStill).isEmpty && freshG.phase == .idle, "hand gestures: fingers closed at a fresh start do not click")
    fresh = [handFrame(0.6), handFrame(0.6), handFrame(0.1), handFrame(0.1)]
    check(handPresses(handRun(freshG, from: 6 * handFrameMs, fresh)).count == 1, "hand gestures: once they have opened, a pinch clicks again")
}
