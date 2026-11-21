import Foundation

func settingsChecks() {
    readabilityChecks()

    // An older file with only some keys takes the defaults for the rest.
    let old = Data(#"{"screens": 3, "widthDeg": 55}"#.utf8)
    let s = try? JSONDecoder().decode(SpaceSettings.self, from: old)
    check(s?.screens == 3, "screens read")
    check(s?.widthDeg == 55, "width read")
    check(s?.distance == 1.4, "distance defaults")
    check(s?.trackingMode == .bodyAnchor, "tracking mode defaults")

    var wild = SpaceSettings()
    wild.screens = 9
    wild.curve = -1
    wild.ipdMm = 10
    let c = wild.clamped
    check(c.screens == 3 && c.curve == 0 && c.ipdMm == 54, "values brought inside their ranges")

    let back = try? JSONDecoder().decode(SpaceSettings.self, from: JSONEncoder().encode(SpaceSettings()))
    check(back == SpaceSettings(), "a round trip keeps every value")

    // Steady mode's screen gap and the remembered Steady mode.
    check(SpaceSettings().steadyGapDeg == 0.6, "screen gap defaults to 0.6 degrees, as before it could be set")
    check(SpaceSettings().steadyOn == false, "Steady mode is not remembered on until it is turned on")
    check(SpaceSettings.steadyGapRange == 0.0...3.0, "screen gap runs from 0 to 3 degrees")
    check(s?.steadyGapDeg == 0.6 && s?.steadyOn == false, "an older file takes the screen gap and Steady defaults")
    var gaps = SpaceSettings()
    gaps.steadyGapDeg = -1
    check(gaps.clamped.steadyGapDeg == 0, "a screen gap below 0 is brought to 0")
    gaps.steadyGapDeg = 9
    check(gaps.clamped.steadyGapDeg == 3, "a screen gap above 3 is brought to 3")
    gaps.steadyGapDeg = 1.7
    check(gaps.clamped.steadyGapDeg == 1.7, "a screen gap in range is kept")
    var steady = SpaceSettings()
    steady.steadyGapDeg = 2.3
    steady.steadyOn = true
    let json = (try? JSONEncoder().encode(steady)) ?? Data()
    let text = String(decoding: json, as: UTF8.self)
    check(text.contains("\"steadyGapDeg\"") && text.contains("\"steadyOn\""), "the screen gap and Steady mode are saved under their own keys")
    let steadyBack = try? JSONDecoder().decode(SpaceSettings.self, from: json)
    check(steadyBack?.steadyGapDeg == 2.3 && steadyBack?.steadyOn == true, "a round trip keeps the screen gap and Steady mode")
    let file = Data(#"{"steadyGapDeg": 7.5, "steadyOn": true}"#.utf8)
    let fromFile = (try? JSONDecoder().decode(SpaceSettings.self, from: file))?.clamped
    check(fromFile?.steadyGapDeg == 3 && fromFile?.steadyOn == true, "a settings file's screen gap is read and clamped")
}

private func readabilityChecks() {
    // Off by default, and an older file without it reads as off.
    check(!SpaceSettings().readability && SpaceSettings().readabilityBefore == nil, "Readability is off by default")
    let older = try? JSONDecoder().decode(SpaceSettings.self, from: Data(#"{"screens": 3}"#.utf8))
    check(older?.readability == false && older?.readabilityBefore == nil, "an older file has Readability off")
    check(SpaceSettings().screenSize.width == 1920 && SpaceSettings().screenSize.height == 1080, "the usual screens are 1920x1080")

    // On: one screen, 1440x810, 34 degrees, no screen moves; everything else left alone.
    var s = SpaceSettings()
    s.screens = 3
    s.widthDeg = 55
    s.layout = .mainSide
    s.distance = 2.2
    s.curve = 0.7
    s.sharperText = true
    s.offsetYawDeg = 12
    s.screenYawDeg = [0, 4, -3]
    s.screenPitchDeg = [1, 0, 0]
    let before = s
    s.setReadability(true)
    check(s.readability && s.screens == 1 && s.widthDeg == 34, "Readability on: one screen, 34 degrees wide")
    check(s.screenSize.width == 1440 && s.screenSize.height == 810, "Readability on: the screen is 1440x810")
    check(abs(Double(s.screenSize.width) / Double(s.screenSize.height) - 16.0 / 9) < 1e-9, "the same 16:9 shape")
    check(s.screenYawDeg.isEmpty && s.screenPitchDeg.isEmpty && !s.screensMoved, "Readability on: the screen is centred")
    check(s.layout == .mainSide && s.distance == 2.2 && s.curve == 0.7 && s.sharperText && s.offsetYawDeg == 12,
          "Readability leaves the layout, distance, curve, Sharper text and the Space's place alone")
    check(s.readabilityBefore == ReadabilityBefore(screens: 3, widthDeg: 55, screenYawDeg: [0, 4, -3], screenPitchDeg: [1, 0, 0]),
          "what it changed is kept")

    // Twice on changes nothing more (the kept values are not overwritten by its own).
    var twice = s
    twice.setReadability(true)
    check(twice == s, "turning it on again does nothing")

    // Kept across a restart: written and read back as it is.
    let json = (try? JSONEncoder().encode(s)) ?? Data()
    let back = try? JSONDecoder().decode(SpaceSettings.self, from: json)
    check(back == s, "Readability and what it changed survive a restart")

    // Off: exactly as before.
    s.setReadability(false)
    check(s == before, "Readability off puts everything back exactly")
    check(s.readabilityBefore == nil && s.screenSize.width == 1920, "and forgets what it kept")
    var offAgain = s
    offAgain.setReadability(false)
    check(offAgain == before, "turning it off again does nothing")

    // Changes made while it is on, to what it set, give way to what was there before.
    var changed = before
    changed.setReadability(true)
    changed.widthDeg = 45
    changed.screens = 2
    changed.setReadability(false)
    check(changed == before, "off puts back the screens and size from before it was on")
    // A change to something it does not touch is kept.
    var other = before
    other.setReadability(true)
    other.distance = 3
    other.setReadability(false)
    check(other.distance == 3 && other.screens == 3 && other.widthDeg == 55, "a change it did not make is kept")

    // A file that says on but lost what it kept turns off without changing the screens.
    var lost = SpaceSettings()
    lost.readability = true
    lost.screens = 1
    lost.widthDeg = 34
    lost.setReadability(false)
    check(!lost.readability && lost.screens == 1 && lost.widthDeg == 34, "off with nothing kept leaves the screens as they are")

    // 1440 across 34 degrees is about 42 pixels a degree, the Air's own; the usual screens are 48.
    check(abs(1440.0 / SpaceSettings.readabilityWidthDeg - 42.35) < 0.1, "about 42 pixels a degree")

    // The log line has the before and after values.
    var on = before
    on.setReadability(true)
    let line = SpaceSettings.readabilityLine(from: before, to: on)
    check(line.contains("Readability: on") && line.contains("screens 3 -> 1") && line.contains("width 55 -> 34")
          && line.contains("screen moves moved -> none") && line.contains("1920x1080 -> 1440x810"), "the log line: \(line)")
}
