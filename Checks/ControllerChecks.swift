import Foundation

func controllerChecks() {
    // The stick: nothing inside the dead zone, then even growth from 0 at its edge to 1 right over.
    let rest = ControllerLogic.stick(x: 0.1, y: -0.1)
    check(rest.x == 0 && rest.y == 0, "stick: at rest inside the dead zone")
    let edge = ControllerLogic.stick(x: 0.18, y: 0)
    check(edge.x == 0 && edge.y == 0, "stick: the dead zone's edge is still rest")
    let full = ControllerLogic.stick(x: 1, y: 0)
    check(near(full.x, 1) && full.y == 0, "stick: right over is 1")
    let half = ControllerLogic.stick(x: 0.59, y: 0)
    check(near(half.x, 0.5), "stick: halfway past the dead zone is a half")
    let corner = ControllerLogic.stick(x: 1, y: 1)
    check(near((corner.x * corner.x + corner.y * corner.y).squareRoot(), 1), "stick: a corner is no faster than 1")
    check(near(corner.x, corner.y), "stick: a diagonal keeps its direction")
    let up = ControllerLogic.stick(x: 0, y: -0.6)
    check(up.x == 0 && up.y < 0, "stick: the sign is kept")
    let odd = ControllerLogic.stick(x: .nan, y: 0.5)
    check(odd.x == 0 && odd.y == 0, "stick: a reading that is not a number is rest")

    check(ControllerLogic.trigger(0.02) == 0, "trigger: at rest")
    check(near(ControllerLogic.trigger(1), 1), "trigger: right down is 1")
    check(near(ControllerLogic.trigger(0.52), 0.5), "trigger: halfway")

    // Speeds: 40 degrees a second for the Space, 25 for the size.
    let right = ControllerSnapshot(rightX: 1, rightY: 0)
    let moved = ControllerLogic.move(right, dt: 0.5)
    check(near(moved.yawDeg, -20) && moved.pitchDeg == 0, "move: the stick to the right is a negative yaw, 40 degrees a second")
    let upward = ControllerLogic.move(ControllerSnapshot(rightX: 0, rightY: 1), dt: 1)
    check(near(upward.pitchDeg, 40) && upward.yawDeg == 0, "move: the stick up is a positive pitch")
    check(near(ControllerLogic.grow(ControllerSnapshot(rightTrigger: 1), dt: 1), 25), "size: the right trigger makes bigger")
    check(near(ControllerLogic.grow(ControllerSnapshot(leftTrigger: 1), dt: 0.2), -5), "size: the left trigger makes smaller")
    check(ControllerLogic.grow(ControllerSnapshot(leftTrigger: 1, rightTrigger: 1), dt: 1) == 0, "size: both triggers cancel")

    // When the controller acts.
    check(!ControllerLogic.active(mode: .off, leftStickIn: true), "mode off: never")
    check(!ControllerLogic.active(mode: .held, leftStickIn: false), "mode held: not without the left stick")
    check(ControllerLogic.active(mode: .held, leftStickIn: true), "mode held: with the left stick in")
    check(ControllerLogic.active(mode: .always, leftStickIn: false), "mode always")

    // Buttons act on the press only.
    let press = ControllerLogic.pressed(before: [.south, .leftStick], now: [.south, .leftStick, .east])
    check(press == [.east], "pressed: only what went down")
    check(ControllerLogic.pressed(before: [.south], now: []).isEmpty, "pressed: letting go is nothing")

    check(!ControllerLogic.continuous(ControllerSnapshot(buttons: [.south, .leftStick], rightX: 0.1)), "timer: off with nothing held that lasts")
    check(ControllerLogic.continuous(ControllerSnapshot(rightX: 0.5)), "timer: on with the stick over")
    check(ControllerLogic.continuous(ControllerSnapshot(leftTrigger: 0.5)), "timer: on with a trigger down")
    check(ControllerLogic.continuous(ControllerSnapshot(buttons: [.up])), "timer: on with the D-pad held")

    // The pointer's round: the Mac's own screen, then each floating screen.
    check(ControllerLogic.nextScreen(current: nil, floating: 2, forward: true) == 0, "round: from the Mac to screen 1")
    check(ControllerLogic.nextScreen(current: 0, floating: 2, forward: true) == 1, "round: on to screen 2")
    check(ControllerLogic.nextScreen(current: 1, floating: 2, forward: true) == nil, "round: the last wraps to the Mac")
    check(ControllerLogic.nextScreen(current: nil, floating: 2, forward: false) == 1, "round: back from the Mac to the last")
    check(ControllerLogic.nextScreen(current: 0, floating: 2, forward: false) == nil, "round: back from screen 1 to the Mac")
    check(ControllerLogic.nextScreen(current: nil, floating: 0, forward: true) == nil, "round: nowhere with no floating screen")
    check(ControllerLogic.nextScreen(current: 7, floating: 2, forward: true) == 0, "round: a screen that is gone counts as the Mac")
    check(ControllerLogic.nextScreen(current: 2, floating: 3, forward: true, includeOwn: false) == 0, "round in Pocket mode: the last wraps to the first")
    check(ControllerLogic.nextScreen(current: 0, floating: 3, forward: false, includeOwn: false) == 2, "round in Pocket mode: back from the first to the last")
    check(ControllerLogic.nextScreen(current: nil, floating: 3, forward: false, includeOwn: false) == 2, "round in Pocket mode: from the Mac back to the last")
    check(ControllerLogic.nextScreen(current: 0, floating: 1, forward: true, includeOwn: false) == 0, "round in Pocket mode: one screen stays")

    // A held D-pad direction: at once, then every 0.25 s, and afresh after letting go.
    var again = ControllerRepeat(every: 0.25)
    check(!again.fires(held: false, now: 0), "repeat: nothing while up")
    check(again.fires(held: true, now: 1.0), "repeat: at once on the press")
    check(!again.fires(held: true, now: 1.1), "repeat: not before 0.25 s")
    check(again.fires(held: true, now: 1.25), "repeat: again at 0.25 s")
    check(!again.fires(held: true, now: 1.4), "repeat: not between")
    check(again.fires(held: true, now: 1.5), "repeat: again at 0.5 s")
    check(again.fires(held: true, now: 9), "repeat: once after a stall")
    check(!again.fires(held: true, now: 9.01), "repeat: no burst after a stall")
    check(!again.fires(held: false, now: 9.02) && again.fires(held: true, now: 9.03), "repeat: a new press acts at once")
    var count = 0
    var counter = ControllerRepeat(every: 0.25)
    for i in 0..<120 where counter.fires(held: true, now: Double(i) / 60) { count += 1 }
    check(count == 8, "repeat: 8 times in 2 s at 60 readings a second (\(count))")

    // The pacer: 60 additions a second come out as 30 writes, and nothing is lost.
    var pacer = ControllerPacer(perSecond: 30)
    var writes = 0
    var total = 0.0
    for i in 0..<60 {
        if let amount = pacer.add(1, now: 10 + Double(i) / 60) {
            writes += 1
            total += amount
        }
    }
    if let rest = pacer.flush() { total += rest }
    check(writes <= 31 && writes >= 29, "pacer: about 30 writes a second (\(writes))")
    check(near(total, 60), "pacer: every bit arrives")
    check(pacer.flush() == nil, "pacer: nothing left after a flush")
    var idle = ControllerPacer(perSecond: 30)
    check(idle.add(0, now: 1) == nil, "pacer: nothing to write is no write")

    // Pocket mode's watch.
    var watch = PocketWatch(lastScreen: 0)
    func step(_ w: inout PocketWatch, _ now: Double, down: Bool = false, cover: Bool = false, screen: Int? = 0,
              floating: Int = 2, glasses: Bool = true) -> PocketWatch.Step {
        w.step(now: now, buttonDown: down, pointerOnCover: cover, pointerScreen: screen, floatingScreens: floating,
               glassesPresent: glasses)
    }
    check(step(&watch, 0, screen: 1) == .stay && watch.lastScreen == 1, "pocket: remembers the screen the pointer is on")
    check(step(&watch, 0.1, cover: true, screen: nil) == .pushBack(1), "pocket: the pointer is put back on the screen it was last on")
    check(step(&watch, 0.2, down: true, cover: false, screen: nil) == .stay, "pocket: a drag is left alone")
    check(step(&watch, 0.3, down: true, cover: true, screen: nil) == .stay, "pocket: the hold begins")
    check(near(watch.progress(now: 0.8), 0.5), "pocket: the ring is half full halfway")
    check(watch.hintShown(now: 0.8), "pocket: the line shows while held")
    check(step(&watch, 1.2, down: true, cover: true, screen: nil) == .stay, "pocket: not yet at 0.9 s")
    check(step(&watch, 1.35, down: true, cover: true, screen: nil) == .leave(.held), "pocket: leaves after 1 s held")

    var let_go = PocketWatch()
    _ = step(&let_go, 0)
    _ = step(&let_go, 1, down: true, cover: true, screen: nil)
    check(step(&let_go, 1.5, cover: true, screen: nil) == .pushBack(0) && let_go.progress(now: 1.5) == 0, "pocket: letting go early starts over")
    check(let_go.hintShown(now: 3) && !let_go.hintShown(now: 6), "pocket: the line lingers a little, then goes")
    _ = step(&let_go, 7, down: true, cover: true, screen: nil)
    check(step(&let_go, 7.9, down: true, cover: true, screen: nil) == .stay, "pocket: a new hold counts from its own start")

    // The click that turned Pocket mode on is not a hold.
    var clicked = PocketWatch()
    check(step(&clicked, 0, down: true, cover: true, screen: nil) == .stay, "pocket: the first click is waited out")
    check(step(&clicked, 2, down: true, cover: true, screen: nil) == .stay && clicked.progress(now: 2) == 0, "pocket: the click that turned it on never leaves")
    check(!clicked.hintShown(now: 2), "pocket: no line for that click")

    var gone = PocketWatch()
    check(step(&gone, 0, floating: 0) == .leave(.noScreens), "pocket: leaves when the floating screens go")
    var dark = PocketWatch()
    check(step(&dark, 0, glasses: false) == .stay, "pocket: the glasses gone for a moment is waited out")
    check(step(&dark, 4.9, glasses: false) == .stay, "pocket: still waiting at 4.9 s")
    check(step(&dark, 5, glasses: false) == .leave(.noGlasses), "pocket: leaves after 5 s without the glasses")
    var blink = PocketWatch()
    _ = step(&blink, 0, glasses: false)
    _ = step(&blink, 3, glasses: true)
    check(step(&blink, 6, glasses: false) == .stay, "pocket: the glasses coming back starts the wait over")
    var fewer = PocketWatch(lastScreen: 2)
    check(step(&fewer, 0, cover: true, screen: nil, floating: 2) == .pushBack(1), "pocket: a remembered screen that is gone becomes the last one")
}
