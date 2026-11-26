import Foundation

// Quick pointer: where Pocket XR draws the pointer itself on a screen (PointerSpot).

func pointerChecks() {
    let screen = (x: 1440.0, y: 0.0, width: 1920.0, height: 1080.0)
    let arrow = (x: 4.0, y: 4.0)
    let size = (width: 32.0, height: 32.0)
    if let r = PointerSpot.rect(pointer: (x: 1440 + 960, y: 540), screen: screen, hotSpot: arrow, size: size) {
        check(abs(r.u - 956.0 / 1920) < 1e-9 && abs(r.v - 536.0 / 1080) < 1e-9, "the picture's corner is the hot spot back from the pointer")
        check(abs(r.width - 32.0 / 1920) < 1e-9 && abs(r.height - 32.0 / 1080) < 1e-9, "its size is a share of the screen")
    } else {
        check(false, "a pointer in the middle of the screen is on it")
    }
    check(PointerSpot.rect(pointer: (x: 1439, y: 540), screen: screen, hotSpot: arrow, size: size) == nil, "left of the screen: not on it")
    check(PointerSpot.rect(pointer: (x: 1440 + 1920, y: 540), screen: screen, hotSpot: arrow, size: size) == nil, "its far edge belongs to the next screen")
    check(PointerSpot.rect(pointer: (x: 1440, y: 0), screen: screen, hotSpot: arrow, size: size)?.u ?? 1 < 0,
          "at the top left corner the picture starts just outside the screen")
    check(PointerSpot.rect(pointer: (x: 1500, y: 10), screen: (x: 0, y: 0, width: 0, height: 0), hotSpot: arrow, size: size) == nil,
          "a screen of no size: nothing")
    let screens = [(x: 0.0, y: 0.0, width: 1440.0, height: 900.0), screen, (x: 3360.0, y: 0.0, width: 1920.0, height: 1080.0)]
    check(PointerSpot.screen(pointer: (x: 3000, y: 100), screens: screens) == 1, "the second screen")
    check(PointerSpot.screen(pointer: (x: 3360, y: 100), screens: screens) == 2, "the third screen's own left edge")
    check(PointerSpot.screen(pointer: (x: 100, y: 1000), screens: screens) == nil, "below the first: none")

    // The setting: off in an older settings file, and kept.
    let old = try? JSONDecoder().decode(SpaceSettings.self, from: Data(#"{"screens": 2}"#.utf8))
    check(old?.quickPointer == false, "Quick pointer is off in an older settings file")
    var on = SpaceSettings()
    on.quickPointer = true
    let back = try? JSONDecoder().decode(SpaceSettings.self, from: JSONEncoder().encode(on))
    check(back?.quickPointer == true, "Quick pointer on is kept")
}
