import Foundation

func settingsChecks() {
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
