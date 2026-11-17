import AppKit
import PocketXRCore
import SwiftUI

// The launcher drawn to picture files, without showing a window, so the design can be looked over away from the
// Mac. The apps are a fixed made-up list with drawn icons, so the pictures are the same on any Mac.

@MainActor
enum LauncherRender {
    nonisolated static let sampleNames: [String] = [
        "App Store", "Books", "Calculator", "Calendar", "Chess", "Clock", "Contacts", "Dictionary", "FaceTime",
        "Find My", "Freeform", "Home", "Keynote", "Mail", "Maps", "Messages", "Music", "News", "Notes", "Numbers",
        "Pages", "Photos", "Podcasts", "Preview", "Reminders", "Safari", "Stocks", "System Settings", "TextEdit",
        "Weather",
    ]
    nonisolated static let samplePins: [String] = ["Safari", "Mail", "Notes", "Music", "Photos", "Maps"]

    /// Renders the launcher over a sample desktop to PNG files in `folder`, each 1920 x 1080 as one floating screen
    /// shows it: the home view (launcher.png), a search with results (launcher-search.png), a search with none
    /// (launcher-none.png), the right-click menu (launcher-menu.png), ten pins with the line that refuses an
    /// eleventh on the second page (launcher-full.png), and the whole thing on a 1280 x 720 screen
    /// (launcher-small.png). Returns the files written.
    static func renderAll(to folder: URL) -> [URL] {
        _ = try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = [URL]()
        let full = CGSize(width: 1920, height: 1080)

        func write(_ model: LauncherModel, _ name: String, _ size: CGSize) {
            let url: URL = folder.appendingPathComponent(name)
            if render(model, size: size, to: url) { written.append(url) }
        }

        write(sampleModel(size: full), "launcher.png", full)

        let search: LauncherModel = sampleModel(size: full)
        search.setQuery("st")
        write(search, "launcher-search.png", full)

        let none: LauncherModel = sampleModel(size: full)
        none.setQuery("garden")
        write(none, "launcher-none.png", full)

        let menu: LauncherModel = sampleModel(size: full)
        let local: Int = 8
        let cell: CGRect = menu.layout.inRoot(LauncherLayout.itemRect(local, searching: false))
        menu.contextClick(at: CGPoint(x: cell.midX + 18, y: cell.midY - 6))
        write(menu, "launcher-menu.png", full)

        let ten: LauncherModel = sampleModel(size: full, pins: Array(sampleNames.prefix(10)))
        ten.state.steady = true
        ten.setPage(1)
        ten.spot = .item(20)
        ten.say("Ten apps are pinned. Unpin one first.")
        write(ten, "launcher-full.png", full)

        let small = CGSize(width: 1280, height: 720)
        write(sampleModel(size: small), "launcher-small.png", small)

        // One picture that is NOT the same on every Mac: this Mac's own apps, icons, battery and Wi-Fi, as the
        // launcher really reads them. It is there to check the reading, not the design.
        let real = LauncherModel(store: SettingsStore(defaults: nil), state: AppState(), actions: nil)
        real.setApps(LauncherApps.scan(leavingOut: Bundle.main.bundlePath))
        real.refreshStatus()
        real.layout = LauncherLayout(root: full, area: CGRect(x: 0, y: 25, width: full.width, height: full.height - 25))
        real.shown = true
        write(real, "launcher-this-mac.png", full)
        return written
    }

    private static func render(_ model: LauncherModel, size: CGSize, to url: URL) -> Bool {
        let view = ZStack {
            LauncherSampleDesktop()
            LauncherRootView(model: model)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.settingsStatic, true)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image: CGImage = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png: Data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func samplePath(_ name: String) -> String { "/Sample/\(name).app" }

    /// The launcher open on a floating screen with an XREAL Aura working: 30 apps, some pinned, a Monday morning.
    private static func sampleModel(size: CGSize, pins: [String] = samplePins) -> LauncherModel {
        let store = SettingsStore(defaults: nil)
        var s: SpaceSettings = store.s
        s.pinnedApps = pins.map(samplePath)
        s.pinsChosen = true
        store.s = s
        let state = AppState()
        state.glassesName = "XREAL Aura"
        state.steadyAvailable = true
        state.virtualScreens = 2
        state.launcherOpen = true
        let model = LauncherModel(store: store, state: state, actions: nil, samples: true)
        model.locale = Locale(identifier: "en_GB")
        var when = DateComponents()
        when.year = 2026; when.month = 11; when.day = 16; when.hour = 9; when.minute = 41
        model.now = Calendar(identifier: .gregorian).date(from: when) ?? Date(timeIntervalSince1970: 1_794_822_060)
        model.battery = LauncherBattery(percent: 82, onMains: false)
        model.wifi = .connected
        // The menu bar of a floating screen takes its top 25 points.
        model.layout = LauncherLayout(root: size, area: CGRect(x: 0, y: 25, width: size.width, height: size.height - 25))
        model.setApps(sampleNames.map { LauncherApp(path: samplePath($0), name: $0) })
        model.shown = true
        return model
    }
}

/// A drawn icon for a made-up app: a rounded square in a muted colour with the name's first letter, the size an
/// app's own icon is inside its box.
struct LauncherSampleIcon: View {
    let name: String

    /// The same colour for the same name on every run (a String's hashValue is not).
    private var hue: Double {
        var sum: UInt32 = 7
        for scalar in name.unicodeScalars { sum = sum &* 31 &+ scalar.value }
        return Double(sum % 360) / 360
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let top = Color(hue: hue, saturation: 0.42, brightness: 0.66)
        let bottom = Color(hue: hue, saturation: 0.50, brightness: 0.44)
        return ZStack {
            shape.fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            Text(String(name.prefix(1)))
                .font(Font.system(size: 32, weight: .medium))
                .foregroundColor(Color.white.opacity(0.94))
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}

/// A made-up desktop under the launcher in the pictures: a dark wallpaper, a menu bar, a light window and a dark
/// one, so the dimming and the panel's edge can be judged against both.
struct LauncherSampleDesktop: View {
    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let h: CGFloat = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color(.sRGB, red: 0.10, green: 0.14, blue: 0.27, opacity: 1), Color(.sRGB, red: 0.23, green: 0.13, blue: 0.27, opacity: 1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color(.sRGB, red: 0.30, green: 0.46, blue: 0.72, opacity: 0.55), Color.clear],
                    center: UnitPoint(x: 0.22, y: 0.78),
                    startRadius: 0,
                    endRadius: w * 0.42
                )
                RadialGradient(
                    colors: [Color(.sRGB, red: 0.78, green: 0.44, blue: 0.50, opacity: 0.40), Color.clear],
                    center: UnitPoint(x: 0.86, y: 0.20),
                    startRadius: 0,
                    endRadius: w * 0.36
                )
                window(light: true, title: "Notes")
                    .frame(width: w * 0.44, height: h * 0.62)
                    .offset(x: w * 0.045, y: h * 0.14)
                window(light: false, title: "Terminal")
                    .frame(width: w * 0.40, height: h * 0.52)
                    .offset(x: w * 0.56, y: h * 0.38)
                HStack(spacing: 18) {
                    Text("Notes").font(Font.system(size: 13, weight: .semibold))
                    Text("File")
                    Text("Edit")
                    Text("View")
                    Text("Window")
                    Spacer()
                    Text("Mon 16 Nov  09:41")
                }
                .font(Font.system(size: 13, weight: .regular))
                .foregroundColor(Color.white.opacity(0.9))
                .padding(.horizontal, 18)
                .frame(width: w, height: 25)
                .background(Color.black.opacity(0.35))
            }
        }
        .accessibilityHidden(true)
    }

    private func window(light: Bool, title: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let page: Color = light ? Color(.sRGB, white: 0.95, opacity: 1) : Color(.sRGB, white: 0.11, opacity: 1)
        let bar: Color = light ? Color(.sRGB, white: 0.88, opacity: 1) : Color(.sRGB, white: 0.17, opacity: 1)
        let ink: Color = light ? Color.black.opacity(0.22) : Color.white.opacity(0.22)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(ink).frame(width: 12, height: 12)
                }
                Spacer()
                Text(title)
                    .font(Font.system(size: 13, weight: .medium))
                    .foregroundColor(light ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(bar)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(ink)
                        .frame(height: 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, CGFloat((i * 53) % 240) + 40)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .background(page)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}
