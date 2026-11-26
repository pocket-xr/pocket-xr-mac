import Foundation

// Matching the glasses' display mode to their 2D / 3D state (StereoMode). A user's XREAL 1S on an M4 Pro (November
// 2026): 3D "all combined in the middle", which is what a 1920 x 1080 picture looks like to glasses in 3D.

private func mode(_ w: Int, _ h: Int, px: Int? = nil, py: Int? = nil, hz: Double = 60) -> DisplayModeInfo {
    DisplayModeInfo(width: w, height: h, pixelWidth: px ?? w, pixelHeight: py ?? h, hz: hz)
}

func stereoChecks() {
    let flat = mode(1920, 1080)
    let wide = mode(3840, 1080)
    check(!flat.sideBySide && wide.sideBySide, "3840 x 1080 is side by side, 1920 x 1080 is not")
    check(mode(1920, 540, px: 3840, py: 1080).sideBySide, "a HiDPI 1920 x 540 mode is side by side by its pixels")
    check(!mode(2560, 1080).sideBySide, "a 21:9 ultrawide is not side by side")

    // The glasses say 3D and the display stayed 1920 x 1080: switch to their 3840 x 1080 mode.
    let offered = [flat, mode(1920, 1080, hz: 72), wide, mode(3840, 1080, hz: 72)]
    check(StereoMode.need(glassesStereo: 1, want3D: true, current: flat, modes: offered) == .switchTo(3),
          "3D with the display at 1920 x 1080: switch to 3840 x 1080 at its highest rate, 72 Hz")
    // Even with the app's 3D off: the glasses' own menu put them in 3D, so the picture must be split for them.
    check(StereoMode.need(glassesStereo: 1, want3D: false, current: flat, modes: offered) == .switchTo(3),
          "3D from the glasses' own menu: the display is switched too")
    // Already side by side, or the glasses in 2D: nothing to do.
    check(StereoMode.need(glassesStereo: 1, want3D: true, current: mode(3840, 1080, hz: 72), modes: offered) == .fine, "already side by side at its fastest")
    check(StereoMode.need(glassesStereo: 0, want3D: true, current: mode(1920, 1080, hz: 72), modes: offered) == .fine, "2D at 1920 x 1080, fastest: right")
    check(StereoMode.need(glassesStereo: 0, want3D: false, current: flat, modes: [flat]) == .fine, "2D, nothing offered: fine")
    // The glasses say 3D and nothing side by side is offered: it cannot be shown.
    check(StereoMode.need(glassesStereo: 1, want3D: true, current: flat, modes: [flat]) == .cannot,
          "3D with no side by side mode offered cannot be shown")
    // No link to ask (not known): with 3D wanted, a side by side mode offered means the glasses are in 3D.
    check(StereoMode.need(glassesStereo: nil, want3D: true, current: flat, modes: offered) == .switchTo(3),
          "not known, 3D wanted, 3840 x 1080 offered: switch")
    check(StereoMode.need(glassesStereo: nil, want3D: false, current: flat, modes: offered) == .switchTo(1),
          "not known and 3D not wanted: stays 1920 x 1080, at its faster rate")
    check(StereoMode.need(glassesStereo: nil, want3D: true, current: flat, modes: [flat]) == .fine,
          "not known, nothing side by side offered: left alone, not called broken")
    check(StereoMode.need(glassesStereo: 1, want3D: true, current: nil, modes: offered) == .switchTo(3), "no current mode read: switch")

    // Picking: the highest rate up to 120 Hz, a 1:1 mode before a scaled one, a HiDPI mode of the same pixels allowed.
    check(StereoMode.pick([mode(3840, 1080, hz: 72), mode(3840, 1080, hz: 60)]) == 0, "72 Hz is picked before 60")
    check(StereoMode.pick([mode(3840, 1080, hz: 60), mode(3840, 1080, hz: 120), mode(3840, 1080, hz: 90)]) == 1, "120 Hz before 90 and 60")
    check(StereoMode.pick([mode(3840, 1080, hz: 144), mode(3840, 1080, hz: 90)]) == 1, "over 120 Hz after 90")
    check(StereoMode.pick([mode(3840, 1080, hz: 0), mode(3840, 1080, hz: 60)]) == 1, "an unknown rate last")
    check(StereoMode.pick([mode(3008, 846, px: 6016, py: 1692), mode(3840, 1080)]) == 1, "a 1:1 mode before a scaled one")
    check(StereoMode.pick([mode(1920, 540, px: 3840, py: 1080)]) == 0, "a HiDPI side by side mode is allowed")
    check(StereoMode.pick([mode(3840, 1080, hz: 50), mode(3840, 1080, hz: 72)]) == 1, "over 60 before under it")
    check(StereoMode.pick([flat, mode(2560, 1080)]) == nil, "nothing side by side: none")

    // Faster at the same size (a developer's XREAL 1S on a Mac, November 2026: "60fps only").
    let modes2D = [mode(1920, 1080, hz: 60), mode(1920, 1080, hz: 90), mode(1920, 1080, hz: 120), mode(1280, 720, hz: 144)]
    check(StereoMode.faster(current: modes2D[0], modes: modes2D) == 2, "1920 x 1080 at 60: 120 Hz of the same size")
    check(StereoMode.faster(current: modes2D[2], modes: modes2D) == nil, "already the fastest: nothing")
    check(StereoMode.faster(current: nil, modes: modes2D) == nil, "no current mode: nothing")
    check(StereoMode.faster(current: mode(1920, 1080, hz: 60), modes: [mode(1920, 1080, hz: 60), mode(1920, 1080, hz: 165)]) == nil,
          "nothing over 120 Hz")
    check(StereoMode.faster(current: mode(1920, 1080, hz: 60), modes: [mode(1920, 1080, px: 3840, py: 2160, hz: 120)]) == nil,
          "a scaled mode is not the same size")
    check(StereoMode.faster(current: mode(1920, 1080, hz: 59.94), modes: [mode(1920, 1080, hz: 60)]) == nil, "60 is not faster than 59.94")
    check(StereoMode.need(glassesStereo: 0, want3D: false, current: modes2D[0], modes: modes2D) == .switchTo(2), "2D at 60 Hz: switch to 120")
    check(StereoMode.need(glassesStereo: 1, want3D: true, current: mode(3840, 1080), modes: [mode(3840, 1080), mode(3840, 1080, hz: 90)]) == .switchTo(1),
          "3D at 60 Hz with 90 offered: switch to 90")

    // Pocket XR's own screens run at the glasses' fastest rate.
    check(StereoMode.screensHz(offered: [60, 90, 120]) == 120, "screens at 120 Hz when the glasses offer it")
    check(StereoMode.screensHz(offered: [60, 72]) == 72, "screens at 72 Hz")
    check(StereoMode.screensHz(offered: [60, 165]) == 60, "over 120 Hz is not used")
    check(StereoMode.screensHz(offered: []) == 60, "nothing known: 60 Hz")
    check(StereoMode.screensHz(offered: [0, 50]) == 60, "never under 60 Hz")
    check(StereoMode.screensHz(offered: [59.94, 119.88]) == 120, "119.88 rounds to 120")

    // The log.
    let line = StereoMode.modesLine([flat, flat, wide], current: flat)
    check(line == "glasses display modes: 1920x1080@60 (current), 3840x1080@60", "the modes line, each once: \(line)")
    check(StereoMode.modesLine([], current: nil) == "glasses display modes: none listed", "no modes listed")
    check(mode(1920, 540, px: 3840, py: 1080).text == "1920x540 (3840x1080 pixels)@60", "a HiDPI mode's text")
}
