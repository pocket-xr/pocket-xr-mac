import Foundation

func tourChecks() {
    // The steps, in order, numbered 1 to 8.
    let steps = Tour.steps
    check(steps == [.welcome, .setup, .screens, .look, .arrange, .depth, .menu, .done], "eight steps in the order shown")
    check(Tour.count == 8, "eight steps")
    check(steps.map { $0.number } == Array(1...8), "numbered 1 to 8")
    check(Set(steps.map { $0.slug }).count == steps.count, "every step has its own file name")

    // Moving stays inside the tour.
    check(Tour.move(.welcome, by: 1) == .setup, "Next goes one on")
    check(Tour.move(.setup, by: -1) == .welcome, "Back goes one back")
    check(Tour.move(.welcome, by: -1) == .welcome, "Back on the first step stays")
    check(Tour.move(.done, by: 1) == .done, "Next on the last step stays")
    check(Tour.move(.setup, by: 99) == .done && Tour.move(.menu, by: -99) == .welcome, "a long move is clamped")
    check(Tour.isFirst(.welcome) && !Tour.isFirst(.setup), "the first step")
    check(Tour.isLast(.done) && !Tour.isLast(.menu), "the last step")

    // It opens by itself only until it has been seen.
    check(Tour.opensByItself(tourSeen: false), "a new install gets the tour")
    check(!Tour.opensByItself(tourSeen: true), "never by itself once seen")
    check(!SpaceSettings().tourSeen, "a fresh settings file has not seen the tour")

    // What is left at the end.
    check(Tour.remaining(glassesConnected: true, screenRecordingAllowed: true, capturing: 2).isEmpty, "everything ready")
    check(Tour.ready(glassesConnected: true, screenRecordingAllowed: true, capturing: 1), "ready with one screen showing")
    check(Tour.remaining(glassesConnected: false, screenRecordingAllowed: false, capturing: 0) == [.screenRecording, .plugInGlasses],
          "nothing done: Screen Recording first, then the glasses")
    check(Tour.remaining(glassesConnected: false, screenRecordingAllowed: true, capturing: 0) == [.plugInGlasses], "only the glasses left")
    check(Tour.remaining(glassesConnected: true, screenRecordingAllowed: false, capturing: 0) == [.screenRecording],
          "without Screen Recording nothing can show, so only that is listed")
    check(Tour.remaining(glassesConnected: true, screenRecordingAllowed: true, capturing: 0) == [.screensNotShowing],
          "connected glasses with nothing on them are not ready")
    check(!Tour.ready(glassesConnected: true, screenRecordingAllowed: true, capturing: 0), "never \"look up\" at an empty view")
    check(Tour.remaining(glassesConnected: false, screenRecordingAllowed: true, capturing: 2) == [.plugInGlasses],
          "screens captured with no glasses still need the glasses")

    // What is said for each family: only the Aura has been run on a Mac.
    check(Tour.support(nil) == nil, "no glasses, no support line")
    check(Tour.support(.aura) == .tested, "the Aura is tested on a Mac")
    check(Tour.support(.one) == .sameTrackingUntested, "the One family is untested on a Mac")
    check(Tour.support(.air) == .experimentalTracking && Tour.support(.viture) == .experimentalTracking,
          "the Air family and VITURE: experimental head tracking")
    check(Tour.support(.other) == .screensOnly, "other glasses: screens only")
    let tested = [Glasses.Family.aura, .one, .air, .viture, .other].filter { Tour.support($0) == .tested }
    check(tested == [.aura], "nothing but the Aura is called tested")

    // The pictures: every poster and still lies inside its loop and outside the fade, so a still is never blank.
    for step in steps {
        let poster = Tour.poster(step)
        check(poster >= 0, "\(step.slug): the poster is a moment of the picture")
        if let length = Tour.loop(step) {
            check(length >= 5 && length <= 11, "\(step.slug): loops run 5 to 11 seconds")
            let moments = [poster] + Tour.stills(step)
            check(Tour.stills(step).count == 3, "\(step.slug): three more stills")
            check(Set(moments).count == moments.count, "\(step.slug): the stills are different moments")
            for m in moments {
                check(m > Tour.loopFadeIn && m < length - Tour.loopFadeOut, "\(step.slug): \(m) s is outside the fade")
            }
            // The words follow the picture the same way on every pass.
            for m in moments {
                check(Tour.phase(step, m) == Tour.phase(step, m + length * 3), "\(step.slug): the same beat on every loop")
            }
        } else {
            check(Tour.stills(step).isEmpty, "\(step.slug): no loop, no extra stills")
            check(Tour.phase(step, poster) == -1, "\(step.slug): no line is lit by the picture")
        }
    }
    check(near(Tour.loopTime(20.5, 9), 2.5), "loop time wraps")
    check(near(Tour.loopTime(-1, 9), 8), "loop time is never negative")

    // Each poster shows the picture's point.
    check(Tour.phase(.screens, Tour.poster(.screens)) == 1, "Screens: the poster shows a window carried across")
    check(Tour.phase(.screens, 1.0) == 0, "Screens: first the pointer crosses")
    check(Tour.phase(.screens, 8.0) == -1, "Screens: nothing lit in the rest")
    check(Tour.phase(.depth, Tour.poster(.depth)) == 0, "Depth: the poster shows 3D")
    check(Tour.phase(.depth, Tour.depthRowAt + 0.1) == 1, "Depth: then Steady mode's row")
    check(Tour.phase(.menu, Tour.poster(.menu)) == 0, "Menu: the poster shows the menu open")
    check(Tour.phase(.menu, 4.0) == 1 && Tour.phase(.menu, 7.0) == 2, "Menu: then Quit, then the cable unplugged")
    check(Tour.phase(.look, 4.0) == -1, "Look: its one line ticks only when Recentre is really used")

    // Arrange's own demonstration: bigger, then nearer, then curved, all three done at the poster.
    let before = Tour.arrangeDemo(0.2)
    check(before.bigger == 0 && before.nearer == 0 && before.curved == 0, "Arrange: starts from the plain arrangement")
    let mid = Tour.arrangeDemo(Tour.arrangeBeats[0] + Tour.arrangeBeat / 2)
    check(near(mid.bigger, 0.5) && mid.nearer == 0 && mid.curved == 0, "Arrange: one change at a time")
    let poster = Tour.arrangeDemo(Tour.poster(.arrange))
    check(poster.bigger == 1 && poster.nearer == 1 && poster.curved == 1, "Arrange: the poster shows all three changes")
    check(Tour.phase(.arrange, 1.4) == 0 && Tour.phase(.arrange, 3.6) == 1 && Tour.phase(.arrange, 5.8) == 2,
          "Arrange: the control being shown is lit")
    check(Tour.phase(.arrange, 8.5) == -1, "Arrange: nothing lit in the rest")
}
