import AppKit
import PocketXRCore
import SwiftUI

// The launcher's looks: glass over a dimmed screen, in Pocket XR's "Light on glass". It is read in XR glasses, so
// the type is larger than in the Mac's own windows: no app's name is under 15 pt and the clock is large. Every part
// has a fixed size, so where each app sits can be worked out without asking the views (LauncherLayout), which is
// how a right click finds its app.

enum LauncherMetrics {
    static let panel = CGSize(width: 1120, height: 764)
    static let radius: CGFloat = 30
    static let side: CGFloat = 40
    static let inner: CGFloat = 1040
    static let top: CGFloat = 30
    static let strip: CGFloat = 60
    static let gapStrip: CGFloat = 18
    static let buttons: CGFloat = 84
    static let gapButtons: CGFloat = 18
    static let search: CGFloat = 44
    static let gapSearch: CGFloat = 16
    /// The pinned row and the grid, or a search's results.
    static let apps: CGFloat = 426
    static let gapApps: CGFloat = 8
    static let dots: CGFloat = 12
    static let gapDots: CGFloat = 10
    static let hint: CGFloat = 20
    static let bottom: CGFloat = 18

    static let icon: CGFloat = 76
    /// One app: its icon and its name under it.
    static let cell: CGFloat = 100
    static let columns: Int = 6
    static let rows: Int = 3
    static let searchRows: Int = 4
    static let pinGap: CGFloat = 14
    static let rowGap: CGFloat = 6
    static let searchRowGap: CGFloat = 8
    static let maxPinCell: CGFloat = 124
    /// The widest the light behind a hovered or selected app gets.
    static let highlight: CGFloat = 162
    static let buttonCell: CGFloat = 124
    static let buttonCircle: CGFloat = 54
    static let menuWidth: CGFloat = 236
    static let menuRow: CGFloat = 42

    static var appsTop: CGFloat { top + strip + gapStrip + buttons + gapButtons + search + gapSearch }
    static var column: CGFloat { inner / CGFloat(columns) }

    static func pinCell(count: Int) -> CGFloat {
        count > 0 ? min(maxPinCell, (inner / CGFloat(count)).rounded(.down)) : maxPinCell
    }
}

/// Where the panel and its apps are in the window, worked out from the sizes above.
struct LauncherLayout: Equatable {
    /// The window, which covers the floating screen.
    let root: CGSize
    /// What the menu bar and the Dock leave free, from the window's top left.
    let area: CGRect

    init(root: CGSize, area: CGRect? = nil) {
        self.root = root
        self.area = area ?? CGRect(origin: .zero, size: root)
    }

    /// 1 on a 1920 x 1080 screen; smaller screens get the whole panel scaled down to fit.
    var fit: CGFloat {
        let w: CGFloat = (area.width - 64) / LauncherMetrics.panel.width
        let h: CGFloat = (area.height - 48) / LauncherMetrics.panel.height
        return max(min(1, w, h), 0.3)
    }

    var centre: CGPoint { CGPoint(x: area.midX, y: area.midY) }

    /// A point of the window as a point of the panel (its top left at 0,0, its size as in LauncherMetrics).
    func inPanel(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - centre.x) / fit + LauncherMetrics.panel.width / 2,
            y: (p.y - centre.y) / fit + LauncherMetrics.panel.height / 2
        )
    }

    /// A rectangle of the panel as one of the window.
    func inRoot(_ r: CGRect) -> CGRect {
        CGRect(
            x: (r.minX - LauncherMetrics.panel.width / 2) * fit + centre.x,
            y: (r.minY - LauncherMetrics.panel.height / 2) * fit + centre.y,
            width: r.width * fit,
            height: r.height * fit
        )
    }

    /// The pinned app at place [i] of [count], in the panel.
    static func pinRect(_ i: Int, count: Int) -> CGRect {
        let w: CGFloat = LauncherMetrics.pinCell(count: count)
        let x0: CGFloat = LauncherMetrics.side + (LauncherMetrics.inner - w * CGFloat(count)) / 2
        return CGRect(x: x0 + w * CGFloat(i), y: LauncherMetrics.appsTop, width: w, height: LauncherMetrics.cell)
    }

    /// The app at place [local] of the page shown, in the panel.
    static func itemRect(_ local: Int, searching: Bool) -> CGRect {
        let column: Int = local % LauncherMetrics.columns
        let row: Int = local / LauncherMetrics.columns
        let top: CGFloat = LauncherMetrics.appsTop + (searching ? 0 : LauncherMetrics.cell + LauncherMetrics.pinGap)
        let pitch: CGFloat = LauncherMetrics.cell + (searching ? LauncherMetrics.searchRowGap : LauncherMetrics.rowGap)
        return CGRect(
            x: LauncherMetrics.side + LauncherMetrics.column * CGFloat(column),
            y: top + pitch * CGFloat(row),
            width: LauncherMetrics.column,
            height: LauncherMetrics.cell
        )
    }

    /// The app under a point of the window, if any.
    func spot(at point: CGPoint, pins: Int, page: Range<Int>, searching: Bool) -> LauncherSpot? {
        let p: CGPoint = inPanel(point)
        if !searching {
            for i in 0..<pins where Self.pinRect(i, count: pins).contains(p) { return .pin(i) }
        }
        for (local, item) in page.enumerated() where Self.itemRect(local, searching: searching).contains(p) {
            return .item(item)
        }
        return nil
    }
}

// MARK: the whole window

/// The dimmed screen, the panel in its middle, and the right-click menu over both.
struct LauncherRootView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout: LauncherLayout = model.layout
        // It grows a little as it arrives; with Reduce Motion it only fades.
        let grow: CGFloat = (model.shown || reduceMotion) ? 1 : 0.96
        return ZStack(alignment: .topLeading) {
            Color.black
                .opacity(model.shown ? 0.5 : 0)
                .contentShape(Rectangle())
                .onTapGesture { model.onClose(.dismissed) }
                .accessibilityHidden(true)
            LauncherPanelView(model: model)
                .scaleEffect(layout.fit * grow)
                .opacity(model.shown ? 1 : 0)
                .position(layout.centre)
            if let menu = model.menu {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.menu = nil }
                LauncherMenuView(model: model, menu: menu)
                    .offset(menuOffset(menu, layout))
                    .transition(.opacity)
            }
        }
        .frame(width: layout.root.width, height: layout.root.height)
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
        .animation(Animation.lookEnter(Look.quick), value: model.menu)
    }

    /// The menu's top left: just under the pointer, kept inside the window.
    private func menuOffset(_ menu: LauncherMenu, _ layout: LauncherLayout) -> CGSize {
        let height: CGFloat = LauncherMetrics.menuRow * 2 + 12
        let x: CGFloat = min(menu.at.x + 4, layout.root.width - LauncherMetrics.menuWidth - 12)
        let y: CGFloat = min(menu.at.y + 4, layout.root.height - height - 12)
        return CGSize(width: max(x, 12), height: max(y, 12))
    }
}

/// The glass panel and everything on it.
struct LauncherPanelView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            LauncherStrip(model: model)
                .frame(width: LauncherMetrics.inner, height: LauncherMetrics.strip)
                .padding(.top, LauncherMetrics.top)
            LauncherButtonsRow(model: model, store: model.store, state: model.state)
                .frame(height: LauncherMetrics.buttons)
                .padding(.top, LauncherMetrics.gapStrip)
            LauncherSearchField(model: model)
                .frame(height: LauncherMetrics.search)
                .padding(.top, LauncherMetrics.gapButtons)
            LauncherAppsArea(model: model)
                .frame(width: LauncherMetrics.inner, height: LauncherMetrics.apps, alignment: .top)
                .padding(.top, LauncherMetrics.gapSearch)
            LauncherDots(model: model)
                .frame(height: LauncherMetrics.dots)
                .padding(.top, LauncherMetrics.gapApps)
            LauncherHint(model: model)
                .frame(width: LauncherMetrics.inner, height: LauncherMetrics.hint)
                .padding(.top, LauncherMetrics.gapDots)
            Spacer(minLength: 0)
        }
        .frame(width: LauncherMetrics.panel.width, height: LauncherMetrics.panel.height)
        .background(glass)
        .contentShape(RoundedRectangle(cornerRadius: LauncherMetrics.radius, style: .continuous))
        .onTapGesture { model.menu = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Launcher"))
    }

    /// Dark glass that lets a little of the screen through, with light along its rim, strongest at the top.
    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: LauncherMetrics.radius, style: .continuous)
        let fill = LinearGradient(
            colors: [Look.glassTop.color.opacity(0.95), Look.page.color.opacity(0.97)],
            startPoint: .top,
            endPoint: .bottom
        )
        let rim = LinearGradient(
            colors: [Color.white.opacity(0.34), Color.white.opacity(0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
        return shape
            .fill(fill)
            .overlay(shape.strokeBorder(rim, lineWidth: 1))
    }
}

// MARK: the top strip

/// The time, large, and the date; the battery and Wi-Fi on the right.
struct LauncherStrip: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(model.timeText)
                .font(Font.system(size: 52, weight: .light).monospacedDigit())
                .foregroundColor(Color.lookInk)
                .lineLimit(1)
                .fixedSize()
            Text(model.dateText)
                .font(Font.system(size: 21, weight: .regular))
                .foregroundColor(Color.lookInk2)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let wifi = model.wifi {
                LauncherWifiView(wifi: wifi)
            }
            if let battery = model.battery {
                LauncherBatteryView(battery: battery)
                    .padding(.leading, 6)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LauncherWifiView: View {
    let wifi: LauncherWifi

    var body: some View {
        let on: Bool = wifi == .connected
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: on ? "wifi" : "wifi.slash")
                .font(Font.system(size: 17, weight: .medium))
                .foregroundColor(on ? Color.lookInk : Color.lookInk3)
            Text(on ? "Wi-Fi" : "No Wi-Fi")
                .font(Font.system(size: 17, weight: .regular))
                .foregroundColor(on ? Color.lookInk2 : Color.lookInk3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(on ? "Wi-Fi connected" : "Wi-Fi not connected"))
    }
}

/// The battery: its percent and a bar that is as full as it is.
struct LauncherBatteryView: View {
    let battery: LauncherBattery

    private var tint: Color {
        if battery.onMains { return Color.lookGood }
        return battery.percent <= 20 ? Color.lookWarn : Color.lookInk
    }

    var body: some View {
        let fraction: CGFloat = CGFloat(battery.percent) / 100
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if battery.onMains {
                Image(systemName: "bolt.fill")
                    .font(Font.system(size: 13, weight: .medium))
                    .foregroundColor(Color.lookGood)
            }
            Text("\(battery.percent)%")
                .font(Font.system(size: 17, weight: .regular).monospacedDigit())
                .foregroundColor(Color.lookInk)
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.45), lineWidth: 1.5)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(tint)
                        .frame(width: max(3, 28 * fraction), height: 10)
                        .padding(.leading, 3.5)
                }
                .frame(width: 35, height: 17)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 2.5, height: 7)
            }
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery \(battery.percent) percent\(battery.onMains ? ", plugged in" : "")"))
    }
}

// MARK: the round buttons

struct LauncherButtonsRow: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState

    private var shownButtons: [LauncherButton] {
        LauncherButton.allCases.filter { $0 != .steady || state.steadyAvailable }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(shownButtons, id: \.self) { button in
                LauncherRoundButton(button: button, lit: model.isLit(button)) { model.press(button) }
                    .frame(width: LauncherMetrics.buttonCell)
            }
        }
    }
}

/// A round button with its name under it. Lit in the accent while what it switches is on.
struct LauncherRoundButton: View {
    let button: LauncherButton
    let lit: Bool
    let action: () -> Void
    @State private var hover: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                circle
                Text(button.title)
                    .font(Font.system(size: 15, weight: .regular))
                    .foregroundColor(lit || hover ? Color.lookInk : Color.white.opacity(0.74))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: LauncherMetrics.buttonCell, height: LauncherMetrics.buttons, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherPressStyle())
        .onHover { hover = $0 }
        .animation(Animation.lookEnter(Look.quick), value: hover)
        .animation(Animation.lookEnter(0.18), value: lit)
        .accessibilityLabel(Text(button.title))
        .accessibilityValue(Text(button.staysOpen ? (lit ? "On" : "Off") : ""))
    }

    private var circle: some View {
        let fill: Color = lit ? Color.lookAccent : (hover ? Color.lookGlassHover : Look.control.color.opacity(0.78))
        let rim: Color = lit ? Color.lookHeld.opacity(0.9) : (hover ? Color.lookRimFocus : Color.lookRim)
        return ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(rim, lineWidth: 1)
            glyph
                .foregroundColor(lit ? Color.white : Color.lookInk)
        }
        .frame(width: LauncherMetrics.buttonCircle, height: LauncherMetrics.buttonCircle)
    }

    @ViewBuilder
    private var glyph: some View {
        if button == .depth {
            Text("3D")
                .font(Font.system(size: 18, weight: .semibold))
        } else {
            Image(systemName: button.symbol)
                .font(Font.system(size: 21, weight: .regular))
        }
    }
}

/// A press dims a little; nothing bounces.
struct LauncherPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Animation.lookEnter(Look.quick), value: configuration.isPressed)
    }
}

// MARK: search

/// What has been typed. It is not a text field: the window takes the keys itself, so there is nothing to click.
struct LauncherSearchField: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        let typing: Bool = !model.query.isEmpty
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(Font.system(size: 17, weight: .medium))
                .foregroundColor(typing ? Color.lookInk : Color.lookInk3)
            HStack(alignment: .center, spacing: 2) {
                if typing {
                    Text(model.query)
                        .font(Font.system(size: 19, weight: .regular))
                        .foregroundColor(Color.lookInk)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.lookAccent)
                    .frame(width: 2, height: 22)
                if !typing {
                    Text("Search apps")
                        .font(Font.system(size: 19, weight: .regular))
                        .foregroundColor(Color.lookInk3)
                        .padding(.leading, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: 460, height: LauncherMetrics.search)
        .background(Capsule().fill(Color.white.opacity(typing ? 0.09 : 0.06)))
        .overlay(Capsule().strokeBorder(typing ? Color.lookAccent.opacity(0.75) : Color.lookRim, lineWidth: 1))
        .animation(Animation.lookEnter(Look.quick), value: typing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Search apps"))
        .accessibilityValue(Text(model.query))
    }
}

// MARK: apps

/// The pinned row over a page of the grid; or a search's results; or a line saying there are none.
struct LauncherAppsArea: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Group {
            if !model.scanned && model.apps.isEmpty {
                LauncherLine(text: "Looking for apps", detail: nil)
            } else if model.searching {
                if model.listed.isEmpty {
                    LauncherLine(text: "No apps found", detail: "Nothing is called \u{201C}\(model.query)\u{201D}.")
                } else {
                    LauncherGridView(model: model, rows: LauncherMetrics.searchRows, gap: LauncherMetrics.searchRowGap)
                }
            } else {
                VStack(spacing: 0) {
                    LauncherPinsRow(model: model)
                        .frame(height: LauncherMetrics.cell)
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0), Color.white.opacity(0.12), Color.white.opacity(0.12), Color.white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: LauncherMetrics.inner, height: 1)
                        .frame(height: LauncherMetrics.pinGap)
                    LauncherGridView(model: model, rows: LauncherMetrics.rows, gap: LauncherMetrics.rowGap)
                }
            }
        }
        .frame(width: LauncherMetrics.inner, height: LauncherMetrics.apps, alignment: .top)
        .animation(Animation.lookEnter(0.18), value: model.page)
    }
}

/// A quiet line in the middle of the apps' place.
struct LauncherLine: View {
    let text: String
    let detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(Font.system(size: 24, weight: .medium))
                .foregroundColor(Color.lookInk)
            if let detail {
                Text(detail)
                    .font(Font.system(size: 17, weight: .regular))
                    .foregroundColor(Color.lookInk2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

struct LauncherPinsRow: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        let pins: [LauncherApp] = model.pins
        let width: CGFloat = LauncherMetrics.pinCell(count: pins.count)
        return HStack(spacing: 0) {
            if pins.isEmpty {
                Text("Right-click an app to pin it here.")
                    .font(Font.system(size: 16, weight: .regular))
                    .foregroundColor(Color.lookInk3)
            } else {
                ForEach(Array(pins.enumerated()), id: \.element.id) { i, app in
                    LauncherCell(model: model, app: app, spot: .pin(i), width: width)
                }
            }
        }
        .frame(width: LauncherMetrics.inner, height: LauncherMetrics.cell)
    }
}

/// One page of apps, six across.
struct LauncherGridView: View {
    @ObservedObject var model: LauncherModel
    let rows: Int
    let gap: CGFloat

    var body: some View {
        let range: Range<Int> = model.pageRange
        let listed: [LauncherApp] = model.listed
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<LauncherMetrics.columns, id: \.self) { column in
                        cell(range.lowerBound + row * LauncherMetrics.columns + column, range, listed)
                    }
                }
            }
        }
        .frame(width: LauncherMetrics.inner, alignment: .topLeading)
        .id(model.page)
        .transition(.opacity)
    }

    @ViewBuilder
    private func cell(_ index: Int, _ range: Range<Int>, _ listed: [LauncherApp]) -> some View {
        if range.contains(index), listed.indices.contains(index) {
            LauncherCell(model: model, app: listed[index], spot: .item(index), width: LauncherMetrics.column)
        } else {
            Color.clear
                .frame(width: LauncherMetrics.column, height: LauncherMetrics.cell)
        }
    }
}

/// One app: its icon and its name. The pointer over it lifts it a little and lights its name; the arrow keys'
/// selection draws a ring in the accent round it.
struct LauncherCell: View {
    @ObservedObject var model: LauncherModel
    let app: LauncherApp
    let spot: LauncherSpot
    let width: CGFloat
    @State private var hover: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selected: Bool = model.spot == spot
        let held: Bool = model.menu?.spot == spot
        let lit: Bool = hover || selected || held
        let light: CGFloat = min(width - 4, LauncherMetrics.highlight)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            model.open(app)
        } label: {
            // An app's icon has clear space of its own round it, so the name sits close under its box and the room
            // goes below the name, inside the selection's ring.
            VStack(spacing: 0) {
                LauncherIconView(model: model, app: app)
                    .frame(width: LauncherMetrics.icon, height: LauncherMetrics.icon)
                    .scaleEffect(hover && !reduceMotion ? 1.06 : 1)
                Text(app.name)
                    .font(Font.system(size: 15, weight: .regular))
                    .foregroundColor(lit ? Color.white : Color.white.opacity(0.80))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: light - 12, height: 18)
            }
            .padding(.bottom, 5)
            .frame(width: light, height: LauncherMetrics.cell)
            .background(shape.fill(lit ? Color.white.opacity(held ? 0.12 : 0.08) : Color.clear))
            .overlay(ring(shape, selected: selected))
            .frame(width: width, height: LauncherMetrics.cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherPressStyle())
        .onHover { hover = $0 }
        .animation(Animation.lookEnter(Look.quick), value: hover)
        .animation(Animation.lookEnter(Look.quick), value: selected)
        .accessibilityLabel(Text(app.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The selection: a line in the accent with a soft halo of the same light.
    @ViewBuilder
    private func ring(_ shape: RoundedRectangle, selected: Bool) -> some View {
        if selected {
            ZStack {
                shape.stroke(Color.lookAccent.opacity(0.24), lineWidth: 7)
                shape.strokeBorder(Color.lookAccent, lineWidth: 2)
            }
        }
    }
}

/// An app's own icon; in pictures rendered to files, a drawn one that does not depend on what is installed.
struct LauncherIconView: View {
    let model: LauncherModel
    let app: LauncherApp

    var body: some View {
        if model.samples {
            LauncherSampleIcon(name: app.name)
        } else {
            Image(nsImage: model.icons.icon(forPath: app.path))
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        }
    }
}

// MARK: page dots, hint, menu

struct LauncherDots: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        let pages: Int = model.grid.pages
        return HStack(spacing: 4) {
            if pages > 1 {
                ForEach(0..<pages, id: \.self) { p in
                    Button {
                        model.setPage(p)
                    } label: {
                        Circle()
                            .fill(p == model.page ? Color.lookInk : Color.white.opacity(0.28))
                            .frame(width: 8, height: 8)
                            .frame(width: 18, height: LauncherMetrics.dots)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(LauncherPressStyle())
                    .accessibilityLabel(Text("Page \(p + 1) of \(pages)"))
                }
            }
        }
        .frame(height: LauncherMetrics.dots)
        .animation(Animation.lookEnter(0.18), value: model.page)
    }
}

/// The quiet line at the bottom: what the keys do, or for a few seconds why something was not done.
struct LauncherHint: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        ZStack {
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.lookWarn)
                        .frame(width: 7, height: 7)
                    Text(notice)
                        .font(Font.system(size: 15, weight: .regular))
                        .foregroundColor(Color.lookInk)
                }
                .transition(.opacity)
            } else {
                Text(model.hint)
                    .font(Font.system(size: 13.5, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.46))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Animation.lookEnter(Look.quick), value: model.notice)
    }
}

/// The right-click menu, in the launcher's own glass.
struct LauncherMenuView: View {
    @ObservedObject var model: LauncherModel
    let menu: LauncherMenu

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 0) {
            LauncherMenuRow(symbol: menu.pinned ? "pin.slash" : "pin", title: menu.pinned ? "Unpin" : "Pin") {
                model.togglePin(menu.app)
            }
            LauncherMenuRow(symbol: "folder", title: "Show in Finder") {
                model.showInFinder(menu.app)
            }
        }
        .padding(6)
        .frame(width: LauncherMetrics.menuWidth)
        .background(shape.fill(Look.glassRaised.color))
        .overlay(shape.strokeBorder(Color.lookRimFocus, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(menu.app.name))
    }
}

struct LauncherMenuRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(Font.system(size: 16, weight: .regular))
                    .foregroundColor(hover ? Color.white : Color.lookInk2)
                    .frame(width: 22)
                Text(title)
                    .font(Font.system(size: 16, weight: .regular))
                    .foregroundColor(hover ? Color.white : Color.lookInk)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: LauncherMetrics.menuRow)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hover ? Color.lookAccent.opacity(0.9) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherPressStyle())
        .onHover { hover = $0 }
    }
}
