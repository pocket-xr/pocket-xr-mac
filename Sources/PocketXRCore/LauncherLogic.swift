import Foundation

// The launcher's logic that needs no screen: finding apps by name as the user types, the pages of the grid, moving
// the selection with the arrow keys, and the list of pinned apps.

/// Search: by name, whatever the case or the accents; names that start with what was typed come first, then names
/// with a later word that starts with it, then names that have it anywhere.
public enum LauncherSearch {
    /// The longest search that can be typed.
    public static let maxQuery = 40

    /// A name or a search without case and accents, for comparing: "Café" and "cafe" are the same.
    public static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The words of a folded name: runs of letters and digits.
    static func words(_ folded: String) -> [Substring] {
        folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }

    /// How well [name] answers [query], lower is better: 0 the name starts with it, 1 its words start with what was
    /// typed ("sys set" finds System Settings), 2 it is somewhere in the name, 3 every typed word is somewhere in
    /// the name. Nil when it does not match. An empty query matches everything at 0.
    public static func rank(name: String, query: String) -> Int? {
        let q: String = folded(query)
        if q.isEmpty { return 0 }
        let n: String = folded(name)
        if n.hasPrefix(q) { return 0 }
        let typed: [Substring] = q.split(separator: " ")
        let nameWords: [Substring] = words(n)
        let everyWordStarts: Bool = typed.allSatisfy { t in nameWords.contains { $0.hasPrefix(t) } }
        if everyWordStarts { return 1 }
        if n.contains(q) { return 2 }
        if typed.count > 1, typed.allSatisfy({ n.contains($0) }) { return 3 }
        return nil
    }

    /// The places in [names] that match [query], best first; names that match equally well keep the order given.
    public static func results(names: [String], query: String) -> [Int] {
        if folded(query).isEmpty { return Array(names.indices) }
        var ranked = [(rank: Int, index: Int)]()
        for (i, name) in names.enumerated() {
            if let r = rank(name: name, query: query) { ranked.append((r, i)) }
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
        return ranked.map(\.index)
    }

    /// [query] after [text] was typed: no control keys, no space at the start, never longer than [maxQuery].
    public static func typed(_ query: String, adding text: String) -> String {
        var out: String = query
        for ch in text {
            if out.count >= maxQuery { break }
            let printable: Bool = ch.unicodeScalars.allSatisfy { s in
                // 0xF700...0xF8FF is where AppKit puts the arrow and function keys.
                s.value >= 0x20 && s.value != 0x7F && !(0xF700...0xF8FF).contains(s.value)
            }
            if !printable || ch.isNewline { continue }
            if out.isEmpty && ch.isWhitespace { continue }
            out.append(ch)
        }
        return out
    }

    /// [query] with its last character taken off (Backspace).
    public static func erased(_ query: String) -> String {
        String(query.dropLast())
    }
}

/// Pages of a grid.
public enum LauncherPaging {
    /// How many pages [items] need, one at least (an empty page is still a page).
    public static func pageCount(items: Int, perPage: Int) -> Int {
        guard perPage > 0, items > 0 else { return 1 }
        return (items + perPage - 1) / perPage
    }

    public static func clamped(page: Int, items: Int, perPage: Int) -> Int {
        min(max(page, 0), pageCount(items: items, perPage: perPage) - 1)
    }

    /// Which items are on [page].
    public static func range(page: Int, items: Int, perPage: Int) -> Range<Int> {
        guard perPage > 0, items > 0 else { return 0..<0 }
        let p: Int = clamped(page: page, items: items, perPage: perPage)
        return (p * perPage)..<min((p + 1) * perPage, items)
    }

    /// The page [item] is on.
    public static func page(ofItem item: Int, perPage: Int) -> Int {
        perPage > 0 ? max(item, 0) / perPage : 0
    }
}

/// What is selected: a pinned app by its place in the row, or an app in the grid by its place in the whole list.
public enum LauncherSpot: Equatable, Sendable {
    case pin(Int)
    case item(Int)
}

public enum LauncherMove: Sendable {
    case left, right, up, down
}

/// The shape of what the arrow keys move over: a row of pins above a paged grid.
public struct LauncherGrid: Equatable, Sendable {
    public var pins: Int
    public var items: Int
    public var columns: Int
    public var rows: Int

    public init(pins: Int, items: Int, columns: Int, rows: Int) {
        self.pins = max(pins, 0)
        self.items = max(items, 0)
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }

    public var perPage: Int { columns * rows }
    public var pages: Int { LauncherPaging.pageCount(items: items, perPage: perPage) }

    /// The selection and the page after an arrow key. With nothing selected, left and right turn the page, and up
    /// or down pick the first thing there is. Left at the first column goes to the page before, right at the last
    /// column to the page after; up from the top row goes to the pins, down from the pins to the grid.
    public func move(_ spot: LauncherSpot?, _ move: LauncherMove, page: Int) -> (spot: LauncherSpot?, page: Int) {
        let page: Int = LauncherPaging.clamped(page: page, items: items, perPage: perPage)
        guard let spot else {
            switch move {
            case .left: return (nil, max(page - 1, 0))
            case .right: return (nil, min(page + 1, pages - 1))
            case .down:
                if items > 0 { return (.item(page * perPage), page) }
                return (pins > 0 ? .pin(0) : nil, page)
            case .up:
                if pins > 0 { return (.pin(0), page) }
                return (items > 0 ? .item(page * perPage) : nil, page)
            }
        }
        switch spot {
        case .pin(let raw):
            guard pins > 0 else { return self.move(nil, move, page: page) }
            let i: Int = min(max(raw, 0), pins - 1)
            switch move {
            case .left: return (.pin(max(i - 1, 0)), page)
            case .right: return (.pin(min(i + 1, pins - 1)), page)
            case .up: return (.pin(i), page)
            case .down:
                let onPage: Range<Int> = LauncherPaging.range(page: page, items: items, perPage: perPage)
                if onPage.isEmpty { return (.pin(i), page) }
                let column: Int = Self.across(i, of: pins, to: columns)
                return (.item(min(onPage.lowerBound + column, onPage.upperBound - 1)), page)
            }
        case .item(let raw):
            guard items > 0 else { return self.move(nil, move, page: page) }
            let k: Int = min(max(raw, 0), items - 1)
            let p: Int = k / perPage
            let local: Int = k % perPage
            let column: Int = local % columns
            let row: Int = local / columns
            let pageEnd: Int = min((p + 1) * perPage, items)
            switch move {
            case .left:
                if column > 0 { return (.item(k - 1), p) }
                if p > 0 { return (.item((p - 1) * perPage + row * columns + columns - 1), p - 1) }
                return (.item(k), p)
            case .right:
                if column < columns - 1 {
                    return (.item(k + 1 < pageEnd ? k + 1 : k), p)
                }
                if p < pages - 1 { return (.item(min((p + 1) * perPage + row * columns, items - 1)), p + 1) }
                return (.item(k), p)
            case .up:
                if row > 0 { return (.item(k - columns), p) }
                if pins > 0 { return (.pin(Self.across(column, of: columns, to: pins)), p) }
                return (.item(k), p)
            case .down:
                if k + columns < pageEnd { return (.item(k + columns), p) }
                // A shorter last row: go to its end rather than nowhere.
                let lastRow: Int = (pageEnd - 1 - p * perPage) / columns
                if row < lastRow { return (.item(pageEnd - 1), p) }
                return (.item(k), p)
            }
        }
    }

    /// The place among [to] things that sits nearest under (or over) place [i] among [count] things, both rows
    /// spread over the same width.
    static func across(_ i: Int, of count: Int, to: Int) -> Int {
        guard count > 0, to > 0 else { return 0 }
        let middle: Double = (Double(i) + 0.5) / Double(count)
        return min(max(Int((middle * Double(to)).rounded(.down)), 0), to - 1)
    }
}

/// The pinned apps: paths to .app bundles, in the order they were pinned, no path twice, never more than the limit.
public enum LauncherPins {
    public enum Added: Equatable, Sendable {
        case added, already, full
    }

    /// The apps offered as pins on the first run, in this order; the first four that are there are taken.
    public static let defaultNames: [String] = [
        "Safari", "Mail", "Notes", "Music", "Photos", "Maps", "Terminal", "System Settings",
    ]

    /// Where the Mac's own apps live. Terminal is in Utilities.
    public static let defaultFolders: [String] = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities",
    ]

    public static let defaultCount = 4

    /// [pins] without empty paths and repeats (the first is kept), cut to [limit].
    public static func cleaned(_ pins: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var out = [String]()
        for p in pins where !p.isEmpty {
            if out.count >= max(limit, 0) { break }
            if seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    /// Pins [path] at the end. `.already` when it is pinned, `.full` when [limit] apps are; the list is unchanged then.
    public static func adding(_ path: String, to pins: [String], limit: Int) -> (pins: [String], result: Added) {
        let tidy: [String] = cleaned(pins, limit: limit)
        if path.isEmpty || tidy.contains(path) { return (tidy, .already) }
        if tidy.count >= limit { return (tidy, .full) }
        return (tidy + [path], .added)
    }

    public static func removing(_ path: String, from pins: [String]) -> [String] {
        pins.filter { $0 != path }
    }

    /// The pins to show: those whose app is still there. The setting itself is left alone, so an app on a drive
    /// that is not plugged in comes back with the drive.
    public static func shown(_ pins: [String], limit: Int, exists: (String) -> Bool) -> [String] {
        cleaned(pins, limit: limit).filter(exists)
    }

    /// The first run's pins: up to [count] of [defaultNames] that exist, each looked for in [defaultFolders].
    public static func defaults(count: Int = defaultCount, exists: (String) -> Bool) -> [String] {
        var out = [String]()
        for name in defaultNames {
            if out.count >= count { break }
            let found: String? = defaultFolders.map { "\($0)/\(name).app" }.first(where: exists)
            if let found { out.append(found) }
        }
        return out
    }
}
