import Foundation

/// How the screens follow the head, as Pocket XR's Tracking choice has it.
public enum TrackingMode: String, Codable, CaseIterable, Sendable {
    /// The screens stay where they are in the room as the head turns (Pocket XR's default).
    case bodyAnchor
    /// The screens drift after the head, so they are always nearly in front.
    case smoothFollow
}

/// How 1 to 3 screens are placed. Every case works for any count: with one screen `row` is "Center" and the two
/// "main" layouts fall back to it.
public enum ArrangeLayout: String, Codable, CaseIterable, Sendable {
    /// Side by side on an arc (Center, Side by side, Three across).
    case row
    /// The first screen large in front, the others smaller beside it (Main + side, Main + two stacked).
    case mainSide
    /// One above the other.
    case stacked
    /// Far away and large, like a cinema screen (the others beside it).
    case theater
}

/// The focused screen's outline colour, Pocket XR's Glow colour list.
public enum GlowColor: String, Codable, CaseIterable, Sendable {
    case blue, white, purple, pink, green, amber, red
}

/// The fade to black at each eye's edges.
public enum EdgeFade: String, Codable, CaseIterable, Sendable {
    case off, soft, wide
}

/// When a game controller's buttons and sticks change the Space.
public enum ControllerMode: String, Codable, CaseIterable, Sendable {
    /// Never.
    case off
    /// Only while the left stick is held pressed in, so a game on a floating screen keeps the controller to itself.
    case held
    /// Always.
    case always
}

/// How the hands aim the pointer.
public enum HandAim: String, Codable, CaseIterable, Sendable {
    /// The hand aims, a pinch clicks.
    case handRay
    /// The head aims (where you look), a pinch anywhere clicks.
    case lookAndPinch
}

/// A saved arrangement of the screens.
public struct SpacePreset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var layout: ArrangeLayout
    public var widthDeg: Double
    public var distance: Double
    public var curve: Double
    /// Where the Space had been moved to by hand when this was saved (nil in one saved before that could be done).
    public var offsetYawDeg: Double?
    public var offsetPitchDeg: Double?
    /// Single screens moved by hand when this was saved (nil in one saved before that could be done).
    public var screenYawDeg: [Double]?
    public var screenPitchDeg: [Double]?

    public init(id: UUID = UUID(), name: String, layout: ArrangeLayout, widthDeg: Double, distance: Double, curve: Double,
                offsetYawDeg: Double? = nil, offsetPitchDeg: Double? = nil, screenYawDeg: [Double]? = nil, screenPitchDeg: [Double]? = nil) {
        self.screenYawDeg = screenYawDeg
        self.screenPitchDeg = screenPitchDeg
        self.id = id
        self.name = name
        self.layout = layout
        self.widthDeg = widthDeg
        self.distance = distance
        self.curve = curve
        self.offsetYawDeg = offsetYawDeg
        self.offsetPitchDeg = offsetPitchDeg
    }
}

extension SpaceSettings {
    /// The Space is as this saved arrangement has it.
    public func matches(_ p: SpacePreset) -> Bool {
        let sameSize: Bool = abs(p.widthDeg - widthDeg) < 0.01 && abs(p.distance - distance) < 0.001
        let sameShape: Bool = abs(p.curve - curve) < 0.001 && p.layout == layout
        let samePlace: Bool = abs((p.offsetYawDeg ?? 0) - offsetYawDeg) < 0.01 && abs((p.offsetPitchDeg ?? 0) - offsetPitchDeg) < 0.01
        let sameScreens: Bool = Self.sameMoves(p.screenYawDeg ?? [], screenYawDeg) && Self.sameMoves(p.screenPitchDeg ?? [], screenPitchDeg)
        return sameSize && sameShape && samePlace && sameScreens
    }

    /// Two lists of screen moves are the same when every screen's move is, a missing entry counting as none.
    static func sameMoves(_ a: [Double], _ b: [Double]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x: Double = i < a.count ? a[i] : 0
            let y: Double = i < b.count ? b[i] : 0
            if abs(x - y) >= 0.01 { return false }
        }
        return true
    }

    /// A screen has been moved by hand.
    public var screensMoved: Bool {
        screenYawDeg.contains { abs($0) >= 0.01 } || screenPitchDeg.contains { abs($0) >= 0.01 }
    }

    /// Moves one screen by hand, added to where it already is.
    public mutating func moveScreen(_ index: Int, yawDeg: Double, pitchDeg: Double) {
        guard index >= 0, index < Self.screensRange.upperBound else { return }
        while screenYawDeg.count <= index { screenYawDeg.append(0) }
        while screenPitchDeg.count <= index { screenPitchDeg.append(0) }
        screenYawDeg[index] += yawDeg
        screenPitchDeg[index] += pitchDeg
        self = clamped
    }

    /// Puts the Space as a saved arrangement has it.
    public mutating func apply(_ p: SpacePreset) {
        layout = p.layout
        widthDeg = p.widthDeg
        distance = p.distance
        curve = p.curve
        offsetYawDeg = p.offsetYawDeg ?? 0
        offsetPitchDeg = p.offsetPitchDeg ?? 0
        screenYawDeg = p.screenYawDeg ?? []
        screenPitchDeg = p.screenPitchDeg ?? []
        self = clamped
    }

    /// Saves the Space as it is now under the next free name ("Arrangement 3"), and says the name.
    @discardableResult
    public mutating func saveArrangement() -> String {
        var number: Int = presets.count + 1
        var name: String = "Arrangement \(number)"
        while presets.contains(where: { $0.name == name }) {
            number += 1
            name = "Arrangement \(number)"
        }
        presets.append(SpacePreset(name: name, layout: layout, widthDeg: widthDeg, distance: distance, curve: curve,
                                   offsetYawDeg: offsetYawDeg, offsetPitchDeg: offsetPitchDeg,
                                   screenYawDeg: screensMoved ? screenYawDeg : nil, screenPitchDeg: screensMoved ? screenPitchDeg : nil))
        return name
    }
}

/// What Readability changed when it was turned on, to be put back exactly when it is turned off.
public struct ReadabilityBefore: Codable, Equatable, Sendable {
    public var screens: Int
    public var widthDeg: Double
    public var screenYawDeg: [Double]
    public var screenPitchDeg: [Double]

    public init(screens: Int, widthDeg: Double, screenYawDeg: [Double], screenPitchDeg: [Double]) {
        self.screens = screens
        self.widthDeg = widthDeg
        self.screenYawDeg = screenYawDeg
        self.screenPitchDeg = screenPitchDeg
    }
}

/// Every setting Pocket XR for Mac keeps between runs. One Codable value: it is the settings file (Save settings to a
/// file, Restore) and what UserDefaults holds. A missing field in an older file takes its default.
public struct SpaceSettings: Codable, Equatable, Sendable {
    // The Space
    /// Virtual displays, 1 to 3. Takes effect when Pocket XR starts.
    public var screens = 2
    public var layout = ArrangeLayout.row
    /// Each screen's width as seen, degrees.
    public var widthDeg = 40.0
    /// Metres from the head.
    public var distance = 1.4
    /// 0 flat, 1 bent round the head like a curved monitor, up to 2.5.
    public var curve = 0.0
    /// HiDPI virtual displays (twice the pixels). Takes effect when Pocket XR starts.
    public var sharperText = false
    public var presets = [SpacePreset]()
    /// Where the whole Space has been moved to by hand, degrees from where Recentre put it (left and up positive).
    /// Recentre brings it back to 0.
    public var offsetYawDeg = 0.0
    public var offsetPitchDeg = 0.0
    /// Single screens moved by hand, on top of the layout: degrees for each screen in order (left and up positive).
    /// A screen with no entry has not been moved. A change of layout clears them.
    public var screenYawDeg = [Double]()
    public var screenPitchDeg = [Double]()
    /// Steady mode: how large the row of screens is drawn on the glasses' flat picture, 1 filling it. Smaller looks
    /// further away; larger runs off the sides (Head scroll slides it).
    public var steadyZoom = 1.0
    /// Steady mode: the space between screens in the row, degrees of the glasses' flat picture.
    public var steadyGapDeg = 0.6
    /// Steady mode as the user last chose it. While it is on, Steady mode comes back on when the glasses connect and
    /// their settings link has settled (when Pocket XR starts, or after an unplug). Unplugging or quitting keeps it.
    public var steadyOn = false
    /// Readability: one screen at 1440x810, shown [Self.readabilityWidthDeg] wide, so text is larger and drawn about one
    /// screen pixel to one glasses pixel. Off by default; turned on and off with [setReadability], which keeps what it
    /// changed in [readabilityBefore] and puts it back. The screen's size takes effect when Pocket XR opens again.
    public var readability = false
    /// What Readability changed, kept while it is on: put back exactly when it is turned off.
    public var readabilityBefore: ReadabilityBefore?

    // The picture
    /// 3D side by side: each eye its own picture.
    public var want3D = true
    /// Eye distance, millimetres.
    public var ipdMm = 63.0
    /// The focused screen's outline, 0 off to 1.
    public var glow = 1.0
    public var glowColor = GlowColor.blue
    public var edgeFade = EdgeFade.soft
    /// The screens' brightness in the glasses, 0.3 to 1.
    public var brightness = 1.0

    // Head tracking
    public var headTracking = true
    public var trackingMode = TrackingMode.bodyAnchor
    /// Recentre with the head more than 15 degrees up or down puts the screens where you look.
    public var recentreFollowsTilt = true
    public var drawSmoothing = true
    public var stillLock = true
    /// The glasses' display delay the pose is predicted across, milliseconds.
    public var displayDelayMs = 8.0
    /// Turning the head slides the row of screens (Smooth Follow and Steady mode).
    public var headScroll = false
    /// The pointer jumps to the screen you look at when it is on another screen.
    public var pointerFollowsHead = false

    // Steady mode
    /// Steady mode uses the glasses' Spatial Anchor (6DoF) where they have it.
    public var steadySixDof = true
    /// Head tracking over USB HID for the XREAL Air family and VITURE (untested on a Mac).
    public var hidTracking = false

    // The app
    public var shortcuts = true
    public var launchAtLogin = false
    public var tourSeen = false
    /// The control panel opens on the Mac's screen when Pocket XR starts.
    public var panelAtStart = true
    /// The launcher's pinned apps, as paths to the .app bundles, 10 at most. Empty until the first run picks some.
    public var pinnedApps = [String]()
    /// The first run has picked the pinned apps (so an emptied list stays empty).
    public var pinsChosen = false
    public var controllerMode = ControllerMode.held
    /// Hand tracking starts with the glasses.
    public var handsOn = false
    public var handAim = HandAim.handRay
    /// Holding Control and Option, moving the mouse moves the Space and scrolling resizes it.
    public var grabKeys = true

    public init() {}

    public static let screensRange = 1...3
    public static let widthRange = 15.0...100.0
    public static let distanceRange = 0.5...6.0
    public static let curveRange = 0.0...2.5
    public static let ipdRange = 54.0...74.0
    public static let brightnessRange = 0.3...1.0
    public static let delayRange = 0.0...40.0
    public static let offsetYawRange = -90.0...90.0
    public static let maxPinnedApps = 10
    public static let steadyZoomRange = 0.4...1.6
    public static let steadyGapRange = 0.0...3.0
    public static let offsetPitchRange = -40.0...40.0

    /// The virtual displays' size: 1920x1080, or 1440x810 (the same 16:9 shape) with Readability on.
    public static let normalScreenSize = (width: 1920, height: 1080)
    public static let readabilityScreenSize = (width: 1440, height: 810)
    /// Readability's screen width as seen. Glasses with a 1920 pixel wide picture across about 46 degrees (the XREAL
    /// Air) show about 42 pixels a degree; 1440 pixels across 34 degrees is 42 a degree, so each screen pixel is about one
    /// glasses pixel. The usual 1920 pixels across 40 degrees is 48 a degree: text smaller, and squeezed. (The tester's
    /// own change used 30 degrees, 48 pixels a degree, which on a Mac draws text no larger than the usual screens.)
    public static let readabilityWidthDeg = 34.0

    /// The size each virtual display is made at.
    public var screenSize: (width: Int, height: Int) { readability ? Self.readabilityScreenSize : Self.normalScreenSize }

    /// Turns Readability on or off. On keeps the screens, size and screen moves as they are, then sets one screen,
    /// [readabilityWidthDeg] wide, centred (no screen moves). Off puts exactly those back. Doing it twice does nothing
    /// more. Changes nothing else: layout, distance, curve, Sharper text and the Space's own place are left alone.
    public mutating func setReadability(_ on: Bool) {
        guard on != readability else { return }
        if on {
            readabilityBefore = ReadabilityBefore(screens: screens, widthDeg: widthDeg, screenYawDeg: screenYawDeg, screenPitchDeg: screenPitchDeg)
            screens = 1
            widthDeg = Self.readabilityWidthDeg
            screenYawDeg = []
            screenPitchDeg = []
        } else if let b = readabilityBefore {
            screens = b.screens
            widthDeg = b.widthDeg
            screenYawDeg = b.screenYawDeg
            screenPitchDeg = b.screenPitchDeg
        }
        readability = on
        if !on { readabilityBefore = nil }
    }

    /// What the log says Readability changed: the values it set, from and to.
    public static func readabilityLine(from old: SpaceSettings, to new: SpaceSettings) -> String {
        func size(_ s: SpaceSettings) -> String { "\(s.screenSize.width)x\(s.screenSize.height)" }
        func deg(_ d: Double) -> String { String(format: "%.0f", d) }
        func moved(_ s: SpaceSettings) -> String { s.screensMoved ? "moved" : "none" }
        return "Readability: \(new.readability ? "on" : "off"); screens \(old.screens) -> \(new.screens), width \(deg(old.widthDeg)) -> "
            + "\(deg(new.widthDeg)) degrees, screen moves \(moved(old)) -> \(moved(new)), display \(size(old)) -> \(size(new))"
    }

    /// Every value brought inside its range (a hand-edited or older file).
    public var clamped: SpaceSettings {
        var s = self
        s.screens = min(max(s.screens, Self.screensRange.lowerBound), Self.screensRange.upperBound)
        s.widthDeg = min(max(s.widthDeg, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        s.distance = min(max(s.distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        s.curve = min(max(s.curve, Self.curveRange.lowerBound), Self.curveRange.upperBound)
        s.ipdMm = min(max(s.ipdMm, Self.ipdRange.lowerBound), Self.ipdRange.upperBound)
        s.glow = min(max(s.glow, 0), 1)
        s.brightness = min(max(s.brightness, Self.brightnessRange.lowerBound), Self.brightnessRange.upperBound)
        s.displayDelayMs = min(max(s.displayDelayMs, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        s.offsetYawDeg = min(max(s.offsetYawDeg, Self.offsetYawRange.lowerBound), Self.offsetYawRange.upperBound)
        s.offsetPitchDeg = min(max(s.offsetPitchDeg, Self.offsetPitchRange.lowerBound), Self.offsetPitchRange.upperBound)
        s.screenYawDeg = s.screenYawDeg.prefix(Self.screensRange.upperBound).map { min(max($0, Self.offsetYawRange.lowerBound), Self.offsetYawRange.upperBound) }
        s.screenPitchDeg = s.screenPitchDeg.prefix(Self.screensRange.upperBound).map { min(max($0, Self.offsetPitchRange.lowerBound), Self.offsetPitchRange.upperBound) }
        s.steadyZoom = min(max(s.steadyZoom, Self.steadyZoomRange.lowerBound), Self.steadyZoomRange.upperBound)
        s.steadyGapDeg = min(max(s.steadyGapDeg, Self.steadyGapRange.lowerBound), Self.steadyGapRange.upperBound)
        if s.pinnedApps.count > Self.maxPinnedApps { s.pinnedApps = Array(s.pinnedApps.prefix(Self.maxPinnedApps)) }
        return s
    }

    // A missing key takes the default, so older files and newer apps get along.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpaceSettings()
        screens = try c.decodeIfPresent(Int.self, forKey: .screens) ?? d.screens
        layout = try c.decodeIfPresent(ArrangeLayout.self, forKey: .layout) ?? d.layout
        widthDeg = try c.decodeIfPresent(Double.self, forKey: .widthDeg) ?? d.widthDeg
        distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? d.distance
        curve = try c.decodeIfPresent(Double.self, forKey: .curve) ?? d.curve
        sharperText = try c.decodeIfPresent(Bool.self, forKey: .sharperText) ?? d.sharperText
        presets = try c.decodeIfPresent([SpacePreset].self, forKey: .presets) ?? d.presets
        want3D = try c.decodeIfPresent(Bool.self, forKey: .want3D) ?? d.want3D
        ipdMm = try c.decodeIfPresent(Double.self, forKey: .ipdMm) ?? d.ipdMm
        glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? d.glow
        glowColor = try c.decodeIfPresent(GlowColor.self, forKey: .glowColor) ?? d.glowColor
        edgeFade = try c.decodeIfPresent(EdgeFade.self, forKey: .edgeFade) ?? d.edgeFade
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        headTracking = try c.decodeIfPresent(Bool.self, forKey: .headTracking) ?? d.headTracking
        trackingMode = try c.decodeIfPresent(TrackingMode.self, forKey: .trackingMode) ?? d.trackingMode
        recentreFollowsTilt = try c.decodeIfPresent(Bool.self, forKey: .recentreFollowsTilt) ?? d.recentreFollowsTilt
        drawSmoothing = try c.decodeIfPresent(Bool.self, forKey: .drawSmoothing) ?? d.drawSmoothing
        stillLock = try c.decodeIfPresent(Bool.self, forKey: .stillLock) ?? d.stillLock
        displayDelayMs = try c.decodeIfPresent(Double.self, forKey: .displayDelayMs) ?? d.displayDelayMs
        headScroll = try c.decodeIfPresent(Bool.self, forKey: .headScroll) ?? d.headScroll
        pointerFollowsHead = try c.decodeIfPresent(Bool.self, forKey: .pointerFollowsHead) ?? d.pointerFollowsHead
        steadySixDof = try c.decodeIfPresent(Bool.self, forKey: .steadySixDof) ?? d.steadySixDof
        hidTracking = try c.decodeIfPresent(Bool.self, forKey: .hidTracking) ?? d.hidTracking
        shortcuts = try c.decodeIfPresent(Bool.self, forKey: .shortcuts) ?? d.shortcuts
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        tourSeen = try c.decodeIfPresent(Bool.self, forKey: .tourSeen) ?? d.tourSeen
        offsetYawDeg = try c.decodeIfPresent(Double.self, forKey: .offsetYawDeg) ?? d.offsetYawDeg
        offsetPitchDeg = try c.decodeIfPresent(Double.self, forKey: .offsetPitchDeg) ?? d.offsetPitchDeg
        panelAtStart = try c.decodeIfPresent(Bool.self, forKey: .panelAtStart) ?? d.panelAtStart
        grabKeys = try c.decodeIfPresent(Bool.self, forKey: .grabKeys) ?? d.grabKeys
        pinnedApps = try c.decodeIfPresent([String].self, forKey: .pinnedApps) ?? d.pinnedApps
        pinsChosen = try c.decodeIfPresent(Bool.self, forKey: .pinsChosen) ?? d.pinsChosen
        controllerMode = try c.decodeIfPresent(ControllerMode.self, forKey: .controllerMode) ?? d.controllerMode
        handsOn = try c.decodeIfPresent(Bool.self, forKey: .handsOn) ?? d.handsOn
        handAim = try c.decodeIfPresent(HandAim.self, forKey: .handAim) ?? d.handAim
        steadyZoom = try c.decodeIfPresent(Double.self, forKey: .steadyZoom) ?? d.steadyZoom
        steadyGapDeg = try c.decodeIfPresent(Double.self, forKey: .steadyGapDeg) ?? d.steadyGapDeg
        steadyOn = try c.decodeIfPresent(Bool.self, forKey: .steadyOn) ?? d.steadyOn
        readability = try c.decodeIfPresent(Bool.self, forKey: .readability) ?? d.readability
        readabilityBefore = try c.decodeIfPresent(ReadabilityBefore.self, forKey: .readabilityBefore) ?? d.readabilityBefore
        screenYawDeg = try c.decodeIfPresent([Double].self, forKey: .screenYawDeg) ?? d.screenYawDeg
        screenPitchDeg = try c.decodeIfPresent([Double].self, forKey: .screenPitchDeg) ?? d.screenPitchDeg
    }
}
