import Foundation

/// Where macOS should put each floating screen's display, so the pointer moves between them the way they look in
/// the glasses: screens side by side are left and right of each other, screens stacked are above and below.
public enum DisplayGrid {
    /// Each screen's top left corner in display points (x right, y down), from where the screens sit in the Space
    /// ([panels], one per screen, in the screens' order) and the displays' sizes. Screens at the same turn of the
    /// head form a column, upper ones first; columns run left to right and are centred on each other. The first
    /// column's top is y 0 and its left is x 0, so the caller can set it against the Mac's own screen.
    /// With a count that does not match, a plain row.
    public static func origins(panels: [PanelPlacement], sizes: [(width: Int, height: Int)]) -> [(x: Int, y: Int)] {
        let n = sizes.count
        guard n > 0 else { return [] }
        guard panels.count == n else {
            var x = 0
            return sizes.map { s in
                defer { x += s.width }
                return (x: x, y: 0)
            }
        }
        // Columns: screens whose middles are closer in yaw than half the narrower one's width.
        var columns = [[Int]]()
        let order = (0..<n).sorted { panels[$0].yawDeg > panels[$1].yawDeg } // left first (left is positive)
        for i in order {
            if let last = columns.last, let j = last.first,
               abs(panels[j].yawDeg - panels[i].yawDeg) < min(panels[j].widthDeg, panels[i].widthDeg) / 2 {
                columns[columns.count - 1].append(i)
            } else {
                columns.append([i])
            }
        }
        for c in columns.indices {
            columns[c].sort { panels[$0].pitchDeg > panels[$1].pitchDeg } // upper first (up is positive)
        }
        let heights: [Int] = columns.map { $0.reduce(0) { $0 + sizes[$1].height } }
        let tallest = heights.max() ?? 0
        let firstTop = (tallest - (heights.first ?? 0)) / 2
        var out = [(x: Int, y: Int)](repeating: (x: 0, y: 0), count: n)
        var x = 0
        for (c, column) in columns.enumerated() {
            var y = (tallest - heights[c]) / 2 - firstTop
            var widest = 0
            for i in column {
                out[i] = (x: x, y: y)
                y += sizes[i].height
                widest = max(widest, sizes[i].width)
            }
            x += widest
        }
        return out
    }
}
