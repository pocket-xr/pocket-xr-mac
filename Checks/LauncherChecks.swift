import Foundation

func launcherChecks() {
    // Search: case and accents do not matter; starts of names first, then starts of words, then anywhere.
    let names = ["App Store", "Books", "Café Notes", "Maps", "Notes", "Photo Booth", "Safari", "System Settings", "TextEdit"]
    check(LauncherSearch.rank(name: "Safari", query: "SAF") == 0, "case does not matter")
    check(LauncherSearch.rank(name: "Café Notes", query: "cafe") == 0, "accents do not matter")
    check(LauncherSearch.rank(name: "Cafe", query: "café") == 0, "accents typed do not matter either")
    check(LauncherSearch.rank(name: "System Settings", query: "set") == 1, "a later word's start")
    check(LauncherSearch.rank(name: "System Settings", query: "sys set") == 1, "two words' starts")
    check(LauncherSearch.rank(name: "TextEdit", query: "edit") == 2, "anywhere in the name")
    check(LauncherSearch.rank(name: "Photo Booth", query: "oto oth") == 3, "every typed word somewhere")
    check(LauncherSearch.rank(name: "Maps", query: "x") == nil, "no match")
    check(LauncherSearch.rank(name: "Maps", query: "  ") == 0, "only spaces is no search")
    let found = LauncherSearch.results(names: names, query: "no").map { names[$0] }
    check(found == ["Notes", "Café Notes"], "starts of names before starts of words: \(found)")
    let o = LauncherSearch.results(names: names, query: "o").map { names[$0] }
    check(o == ["App Store", "Books", "Café Notes", "Notes", "Photo Booth"], "anywhere keeps the order given: \(o)")
    check(LauncherSearch.results(names: names, query: "") == Array(names.indices), "an empty search is everything")
    check(LauncherSearch.results(names: names, query: "zzz").isEmpty, "nothing found")

    // Typing.
    check(LauncherSearch.typed("", adding: " a") == "a", "no space at the start")
    check(LauncherSearch.typed("a", adding: " b") == "a b", "a space inside is kept")
    check(LauncherSearch.typed("a", adding: "\r\t\u{7F}\u{F700}") == "a", "control and arrow keys add nothing")
    let long = LauncherSearch.typed(String(repeating: "x", count: 39), adding: "abc")
    check(long.count == LauncherSearch.maxQuery && long.hasSuffix("a"), "40 characters at most")
    check(LauncherSearch.erased("abc") == "ab" && LauncherSearch.erased("") == "", "Backspace")

    // Pages.
    check(LauncherPaging.pageCount(items: 0, perPage: 18) == 1, "no apps is still one page")
    check(LauncherPaging.pageCount(items: 18, perPage: 18) == 1, "a full page is one page")
    check(LauncherPaging.pageCount(items: 19, perPage: 18) == 2, "one more makes two")
    check(LauncherPaging.range(page: 1, items: 30, perPage: 18) == 18..<30, "the last page is short")
    check(LauncherPaging.range(page: 9, items: 30, perPage: 18) == 18..<30, "a page too far is the last")
    check(LauncherPaging.range(page: 0, items: 0, perPage: 18).isEmpty, "an empty page")
    check(LauncherPaging.clamped(page: -3, items: 30, perPage: 18) == 0, "a page before the first is the first")
    check(LauncherPaging.page(ofItem: 17, perPage: 18) == 0 && LauncherPaging.page(ofItem: 18, perPage: 18) == 1, "an item's page")

    // Arrow keys: 4 pins over a 6 x 3 grid of 30 apps (two pages; the second has 12).
    let g = LauncherGrid(pins: 4, items: 30, columns: 6, rows: 3)
    check(g.perPage == 18 && g.pages == 2, "grid pages")
    check(g.move(nil, .right, page: 0) == (nil, 1), "with nothing selected, right turns the page")
    check(g.move(nil, .right, page: 1) == (nil, 1), "and stops at the last")
    check(g.move(nil, .left, page: 0) == (nil, 0), "left stops at the first")
    check(g.move(nil, .down, page: 1) == (.item(18), 1), "down picks the page's first app")
    check(g.move(nil, .up, page: 0) == (.pin(0), 0), "up picks the first pin")
    check(g.move(.item(0), .right, page: 0) == (.item(1), 0), "right")
    check(g.move(.item(5), .right, page: 0) == (.item(18), 1), "right at the edge goes to the next page, same row")
    check(g.move(.item(17), .right, page: 0) == (.item(29), 1), "onto a row the next page lacks: its last app")
    check(g.move(.item(18), .left, page: 1) == (.item(5), 0), "left at the edge goes back a page")
    check(g.move(.item(0), .left, page: 0) == (.item(0), 0), "left at the very start stays")
    check(g.move(.item(29), .right, page: 1) == (.item(29), 1), "right at the very end stays")
    check(g.move(.item(7), .up, page: 0) == (.item(1), 0), "up a row")
    check(g.move(.item(0), .up, page: 0) == (.pin(0), 0), "up from the top row to the pins")
    check(g.move(.item(5), .up, page: 0) == (.pin(3), 0), "the nearest pin above")
    check(g.move(.pin(3), .down, page: 0) == (.item(5), 0), "down from a pin to the app under it")
    check(g.move(.pin(0), .left, page: 0) == (.pin(0), 0) && g.move(.pin(3), .right, page: 0) == (.pin(3), 0), "pins stop at their ends")
    check(g.move(.item(12), .down, page: 0) == (.item(12), 0), "down from the bottom row stays")
    let short = LauncherGrid(pins: 0, items: 10, columns: 6, rows: 3)
    check(short.move(.item(5), .down, page: 0) == (.item(9), 0), "down onto a short last row goes to its end")
    check(short.move(.item(2), .up, page: 0) == (.item(2), 0), "no pins: up from the top row stays")
    check(short.move(.item(9), .right, page: 0) == (.item(9), 0), "right at the last app stays")
    let none = LauncherGrid(pins: 0, items: 0, columns: 6, rows: 3)
    check(none.move(nil, .down, page: 0) == (nil, 0) && none.move(.item(3), .left, page: 2) == (nil, 0), "nothing to select")

    // Pins.
    let ten = (1...10).map { "/Applications/A\($0).app" }
    check(LauncherPins.cleaned(["/a", "", "/b", "/a"], limit: 10) == ["/a", "/b"], "no repeats, no empty paths")
    check(LauncherPins.cleaned(ten + ["/x"], limit: 10) == ten, "ten at most")
    let add = LauncherPins.adding("/c", to: ["/a", "/b"], limit: 10)
    check(add.result == .added && add.pins == ["/a", "/b", "/c"], "a pin goes at the end")
    let again = LauncherPins.adding("/a", to: ["/a", "/b"], limit: 10)
    check(again.result == .already && again.pins == ["/a", "/b"], "pinned already")
    let full = LauncherPins.adding("/x", to: ten, limit: 10)
    check(full.result == .full && full.pins == ten, "an eleventh is refused")
    check(LauncherPins.removing("/a", from: ["/a", "/b"]) == ["/b"], "unpin")
    check(LauncherPins.removing("/z", from: ["/a", "/b"]) == ["/a", "/b"], "unpin what is not pinned")
    check(LauncherPins.shown(["/a", "/gone", "/b"], limit: 10) { $0 != "/gone" } == ["/a", "/b"], "pins whose app is gone are not shown")

    // The first run's pins.
    let all = LauncherPins.defaults { _ in true }
    check(all == ["/Applications/Safari.app", "/Applications/Mail.app", "/Applications/Notes.app", "/Applications/Music.app"], "the first four: \(all)")
    let mac: Set<String> = [
        "/Applications/Safari.app", "/System/Applications/Mail.app", "/System/Applications/Maps.app",
        "/System/Applications/Utilities/Terminal.app", "/System/Applications/System Settings.app",
    ]
    let some = LauncherPins.defaults { mac.contains($0) }
    check(some == ["/Applications/Safari.app", "/System/Applications/Mail.app", "/System/Applications/Maps.app", "/System/Applications/Utilities/Terminal.app"], "those that exist, in order: \(some)")
    check(LauncherPins.defaults { _ in false }.isEmpty, "none there, none pinned")
}
