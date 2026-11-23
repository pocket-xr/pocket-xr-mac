import Foundation

func settingsChecks() {
    readabilityChecks()
    stayAwakeChecks()
    textSizeChecks()

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

private func stayAwakeChecks() {
    // Off by default, and off for an older settings file without the key.
    check(!SpaceSettings().stayAwakeOnAdapter, "stay awake is off by default")
    let old = try? JSONDecoder().decode(SpaceSettings.self, from: Data(#"{"screens": 2}"#.utf8))
    check(old?.stayAwakeOnAdapter == false, "an older file leaves stay awake off")
    var on = SpaceSettings()
    on.stayAwakeOnAdapter = true
    let back = try? JSONDecoder().decode(SpaceSettings.self, from: (try? JSONEncoder().encode(on)) ?? Data())
    check(back?.stayAwakeOnAdapter == true, "stay awake on is saved and read back")
    // Held only with the setting on and the Mac on its adapter.
    check(StayAwakeRule.holds(enabled: true, onAdapter: true), "held on the adapter with the setting on")
    check(!StayAwakeRule.holds(enabled: true, onAdapter: false), "not held on battery")
    check(!StayAwakeRule.holds(enabled: false, onAdapter: true), "not held with the setting off")
    check(!StayAwakeRule.holds(enabled: false, onAdapter: false), "not held off and on battery")
    check(StayAwakeRule.line(holding: false, enabled: true, onAdapter: false).contains("on battery"), "the battery line says so")
    check(StayAwakeRule.line(holding: false, enabled: false, onAdapter: true).contains("off"), "the off line says so")
}

/// Text size (a Mac user's 1S on an M4 Pro, November 2026: three screens, text too small, and bringing them Nearer
/// did not help). Nearer and Further change only the distance: each screen keeps its width as seen, so neither the
/// text's size nor where the side screens sit changes. Text size makes text larger at the same width as seen.
func textSizeChecks() {
    check(SpaceSettings().textScale == 100, "text size is Standard by default")
    let old = try? JSONDecoder().decode(SpaceSettings.self, from: Data(#"{"screens": 3}"#.utf8))
    check(old?.textScale == 100, "an older file keeps Standard text")
    check(SpaceSettings.screenSize(textScale: 100) == (1920, 1080), "Standard is 1920 x 1080")
    check(SpaceSettings.screenSize(textScale: 125) == (1536, 864), "125% is 1536 x 864")
    check(SpaceSettings.screenSize(textScale: 150) == (1280, 720), "150% is 1280 x 720")
    var s = SpaceSettings()
    check(!s.hiDPI, "Standard text, no Sharper text: not HiDPI")
    s.textScale = 150
    check(s.screenSize == (1280, 720) && s.hiDPI, "150% is 1280 x 720, drawn HiDPI")
    s.setReadability(true)
    check(s.screenSize == SpaceSettings.readabilityScreenSize && !s.hiDPI, "Readability keeps its own size, not HiDPI")
    s.setReadability(false)
    check(s.screenSize == (1280, 720), "Readability off brings the text size back")
    var odd = SpaceSettings()
    odd.textScale = 140
    check(odd.clamped.textScale == 150, "a size not offered goes to the nearest")
    odd.textScale = 10
    check(odd.clamped.textScale == 100, "too small a size goes to Standard")
    var back = SpaceSettings()
    back.textScale = 125
    let read = try? JSONDecoder().decode(SpaceSettings.self, from: (try? JSONEncoder().encode(back)) ?? Data())
    check(read?.textScale == 125, "text size is saved and read back")

    // Pixels a degree: the usual 1920 across 40 degrees is 48, more than the about 42 the glasses show; 150% is 32.
    check(abs(SpaceSettings.pixelsPerDegree(widthPx: 1920, widthDeg: 40) - 48) < 1e-9, "1920 across 40 degrees is 48 a degree")
    check(abs(SpaceSettings.pixelsPerDegree(widthPx: 1280, widthDeg: 40) - 32) < 1e-9, "1280 across 40 degrees is 32 a degree")

    // The placement: three across at 40 degrees, the side screens' middles 42 degrees out and their outer edges 62,
    // at any distance; each faces the head and keeps its width as seen.
    let aspects = [16.0 / 9, 16.0 / 9, 16.0 / 9]
    for d in [0.5, 1.4, 3.0] {
        let row = SpaceLayout.arrange(layout: .row, aspects: aspects, widthDeg: 40, distance: d, curve: 0)
        check(row.map(\.yawDeg) == [42, 0, -42], "three across: side screens 42 degrees out at \(d) m")
        check(abs(row[0].yawDeg + row[0].widthDeg / 2 - 62) < 1e-9, "the left screen's outer edge is 62 degrees out at \(d) m")
        for p in row {
            let seen = 2 * atan(p.sizeMetres.x / 2 / p.distance) * 180 / .pi
            check(abs(seen - 40) < 1e-9, "each screen is 40 degrees wide as seen at \(d) m")
        }
    }
    // Text size leaves the placement alone: the same widths, the same places.
    var big = SpaceSettings()
    big.screens = 3
    big.textScale = 150
    let a = SpaceLayout.arrange(layout: big.layout, aspects: aspects, widthDeg: big.widthDeg, distance: big.distance, curve: big.curve)
    let b = SpaceLayout.arrange(layout: SpaceSettings().layout, aspects: aspects, widthDeg: SpaceSettings().widthDeg,
                                distance: SpaceSettings().distance, curve: SpaceSettings().curve)
    check(a == b, "text size does not move or widen the screens")
}
