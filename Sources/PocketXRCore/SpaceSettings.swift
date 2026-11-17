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

    public init(id: UUID = UUID(), name: String, layout: ArrangeLayout, widthDeg: Double, distance: Double, curve: Double,
                offsetYawDeg: Double? = nil, offsetPitchDeg: Double? = nil) {
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
        return sameSize && sameShape && samePlace
    }

    /// Puts the Space as a saved arrangement has it.
    public mutating func apply(_ p: SpacePreset) {
        layout = p.layout
        widthDeg = p.widthDeg
        distance = p.distance
        curve = p.curve
        offsetYawDeg = p.offsetYawDeg ?? 0
        offsetPitchDeg = p.offsetPitchDeg ?? 0
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
                                   offsetYawDeg: offsetYawDeg, offsetPitchDeg: offsetPitchDeg))
        return name
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
    /// Steady mode: how large the row of screens is drawn on the glasses' flat picture, 1 filling it. Smaller looks
    /// further away; larger runs off the sides (Head scroll slides it).
    public var steadyZoom = 1.0

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
    public static let offsetPitchRange = -40.0...40.0

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
        s.steadyZoom = min(max(s.steadyZoom, Self.steadyZoomRange.lowerBound), Self.steadyZoomRange.upperBound)
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
    }
}
