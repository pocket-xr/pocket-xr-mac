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
}
