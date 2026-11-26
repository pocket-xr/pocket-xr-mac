import AppKit
import PocketXRCore
import SwiftUI

// Hand tracking's settings, as cards in the settings window's look: on and off with where it stands, which camera
// (with what it sees, for a camera that faces you), how the pointer is aimed, what the hands do (each with a small
// drawing), the two permissions, the aim's calibration or reach, and a plain note that none of this has been tried
// on a Mac yet.

/// The settings for hand tracking, as cards for the settings window's Input pane.
struct HandsSettingsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    let actions: SettingsActionsRef
    /// Hand tracking's own keeping (the camera, the calibration, the reach); the pictures pass one kept in memory.
    @ObservedObject var prefs: HandsPrefs = HandsPrefs.shared

    var body: some View {
        Group {
            trackingCard.settingsArrive(1)
            cameraCard.settingsArrive(2)
            gesturesCard.settingsArrive(3)
            permissionsCard.settingsArrive(4)
            if prefs.facing {
                reachCard.settingsArrive(5)
            } else {
                calibrationCard.settingsArrive(5)
            }
            honestCard.settingsArrive(6)
        }
        .onAppear { HandTracking.current?.refreshCameras() }
    }

    /// The hand's place in the picture moves the pointer (a camera that faces you, and the hand aiming).
    private var air: Bool { prefs.facing && store.s.handAim == .handRay }
    private var look: Bool { store.s.handAim == .lookAndPinch }

    // MARK: on and off

    private var statusTitle: String {
        if !state.handsStatus.isEmpty { return state.handsStatus }
        return state.handsRunning ? "Starting" : "Off"
    }

    private var statusNote: String {
        let line: String = state.handsStatus
        if line == HandTracking.Line.looking || line == HandTracking.Line.lookingAny { return "Trying for 30 seconds, then it stops." }
        if line == HandTracking.Line.noCamera || line == HandTracking.Line.noCameraAny { return "macOS shows no such camera. Choose another under Camera." }
        if line == HandTracking.Line.notAllowed { return "Allow the camera under Permissions, then start hands again." }
        if line == HandTracking.Line.noOpen { return "Another app may be using it." }
        if line == HandTracking.Line.steady { return "A pinch still clicks where the pointer is, and the palm gestures still work." }
        if state.handsRunning {
            if state.handsSeen == 0 {
                return prefs.facing ? "Hold a hand up where the camera can see it." : "Hold a hand up in front of the glasses."
            }
            return look ? "The pointer follows where you look." : "The pointer follows the first hand it saw."
        }
        return prefs.facing ? "Sees your hands through a camera that faces you." : "Sees your hands through the camera in your glasses."
    }

    private var trackingCard: some View {
        SettingsCard("Hand tracking") {
            HStack(alignment: .center, spacing: 12) {
                SettingsDot(lit: state.handsRunning && state.handsSeen > 0)
                SettingsRowText(title: statusTitle, note: statusNote)
                Spacer(minLength: 12)
                SettingsButton(
                    state.handsRunning ? "Stop hands" : "Start hands",
                    kind: state.handsRunning ? .glass : .primary
                ) {
                    actions.target?.setHands(!state.handsRunning)
                }
            }
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.vertical, 10)
            .frame(minHeight: SettingsMetrics.row)
            .accessibilityElement(children: .contain)
            SettingsDivider()
            SettingsToggleRow(
                "Start with the glasses",
                note: "Hand tracking starts when your glasses are plugged in.",
                isOn: $store.s.handsOn
            )
            SettingsDivider()
            HandsChoiceRow(
                title: prefs.facing ? "Air trackpad" : "Hand ray",
                note: prefs.facing ? "Your hand moves the pointer, a pinch clicks." : "The hand aims, a pinch clicks.",
                selected: store.s.handAim == .handRay
            ) {
                store.s.handAim = .handRay
            }
            SettingsDivider()
            HandsChoiceRow(
                title: "Look and pinch",
                note: "Where you look aims, a pinch anywhere clicks.",
                selected: store.s.handAim == .lookAndPinch
            ) {
                store.s.handAim = .lookAndPinch
            }
        }
    }

    // MARK: camera

    private var glassesNote: String {
        if prefs.glassesFound { return "Looks where you look, so your hand aims like a ray." }
        if prefs.camera == .glasses && prefs.fellBack {
            return "These glasses have no camera macOS can open, so your Mac's camera is used: turn it to face you."
        }
        return "These glasses have no camera macOS can open."
    }

    private var cameraCard: some View {
        SettingsCard("Camera") {
            HandsChoiceRow(title: "Glasses' camera", note: glassesNote, selected: prefs.camera == .glasses) {
                prefs.camera = .glasses
            }
            ForEach(prefs.cameras) { item in
                SettingsDivider()
                HandsChoiceRow(
                    title: item.name,
                    note: item.choice == .mac ? "This Mac's own camera. Turn it to face you." : "Point it at you, with your hand in view.",
                    selected: prefs.camera == item.choice
                ) {
                    prefs.camera = item.choice
                }
            }
            if prefs.facing {
                SettingsDivider()
                HandsPreviewRow(prefs: prefs, running: state.handsRunning)
            }
        }
    }

    // MARK: gestures

    private var gesturesCard: some View {
        // The same pose with either camera (HandPalm.towardFace): with a camera that faces you, the back of the hand to it.
        let palm: String = prefs.facing ? "Palm to your face (back of the hand to the camera)" : "Palm to your face"
        let pointTitle: String = look ? "Look" : (air ? "Move your hand" : "Point")
        let pointNote: String = look
            ? "The pointer goes where you look while a hand is in view."
            : (air
                ? "The pointer moves over the screen you are looking at, as on a trackpad in the air."
                : "The pointer goes where your hand is, as you see it through the glasses.")
        return SettingsCard("What your hands do") {
            HandsGestureRow(glyph: .point, title: pointTitle, note: pointNote)
            SettingsDivider()
            HandsGestureRow(
                glyph: .pinch,
                title: "Pinch",
                note: "Thumb and first finger together is a press; apart again is a click."
            )
            SettingsDivider()
            HandsGestureRow(
                glyph: .drag,
                title: "Pinch and move",
                note: look ? "Drags. Keep the pinch and turn your head; let go to drop." : "Drags. Keep the pinch and move your hand; let go to drop."
            )
            SettingsDivider()
            HandsGestureRow(
                glyph: .palmPinch,
                title: "\(palm), then a short pinch",
                note: "Opens or closes the launcher."
            )
            SettingsDivider()
            HandsGestureRow(
                glyph: .palmHold,
                title: "\(palm), pinch and hold",
                note: "Recentres the screens in front of you."
            )
            SettingsDivider()
            SettingsNote("There is no scroll gesture yet. A pinch is a press, moving is a drag, letting go lets go.")
        }
    }

    // MARK: permissions

    private var permissionsCard: some View {
        SettingsCard("Permissions") {
            SettingsRow("Camera", note: "Lets Pocket XR see your hands. The picture is used on this Mac only and is never kept.") {
                if state.cameraAllowed {
                    SettingsChip("Allowed", lit: true)
                } else {
                    SettingsButton("Allow camera", kind: .primary) { HandTracking.requestCamera() }
                }
            }
            SettingsDivider()
            SettingsRow("Accessibility", note: "Lets a pinch click for you.") {
                if state.accessibilityAllowed {
                    SettingsChip("Allowed", lit: true)
                } else {
                    SettingsButton("Allow in System Settings") { actions.target?.requestAccessibility() }
                }
            }
            if !state.accessibilityAllowed {
                SettingsNote("Without it the pointer still follows your hand, but a pinch cannot click yet.", warn: state.handsRunning)
            }
        }
    }

    // MARK: calibration (the glasses' camera) and reach (a camera that faces you)

    private var calibrationCard: some View {
        let blocker: String? = HandTracking.calibrationBlocker(store: store, state: state)
        return SettingsCard("Calibration") {
            SettingsRow(
                "Teach it where you point",
                note: blocker ?? "Five dots on the floating screen your pointer is on. Hold your hand over each one and pinch."
            ) {
                SettingsButton(
                    prefs.calibrating ? "Calibrating" : "Calibrate hand aim",
                    kind: .primary,
                    enabled: blocker == nil && !prefs.calibrating
                ) {
                    HandTracking.current?.beginCalibration()
                }
            }
            SettingsDivider()
            SettingsRow("Start over", note: "Goes back to the estimate of where the camera points.") {
                SettingsButton("Reset calibration", enabled: prefs.calibration != nil && !prefs.calibrating) {
                    HandTracking.current?.resetCalibration()
                }
            }
            SettingsDivider()
            SettingsNote(prefs.lastResult ?? "Not calibrated. The aim uses an estimate of where the camera points.")
        }
    }

    private var reachBlocker: String? {
        if !state.handsRunning { return "Start hands first." }
        if look { return "Look and pinch aims with your head, so there is no reach to set." }
        if state.handsSeen == 0 { return "Hold a hand up where the camera can see it." }
        return nil
    }

    private var reachCard: some View {
        let blocker: String? = reachBlocker
        return SettingsCard("Your reach") {
            SettingsRow(
                "Set your reach",
                note: prefs.settingReach
                    ? "Hold your hand where it is comfortable and pinch."
                    : (blocker ?? "Hold your hand where it is comfortable and pinch. That spot becomes the middle of the screen.")
            ) {
                SettingsButton(
                    prefs.settingReach ? "Pinch now" : "Set your reach",
                    kind: .primary,
                    enabled: blocker == nil && !prefs.settingReach
                ) {
                    HandTracking.current?.beginReach()
                }
            }
            SettingsDivider()
            SettingsRow("Start over", note: "Puts the box back in the middle of the picture, a little low.") {
                SettingsButton("Reset reach", enabled: prefs.reachCentre != nil && !prefs.settingReach) {
                    HandTracking.current?.resetReach()
                }
            }
            SettingsDivider()
            SettingsNote(prefs.reachCentre == nil
                ? "Not set. The box rests in the middle of the picture, a little low."
                : "Set: the box is centred where you pinched.")
        }
    }

    // MARK: the plain truth

    private var honestCard: some View {
        SettingsCard("Not tried on a Mac yet") {
            SettingsNote(
                "Hand tracking has not been tried on a Mac yet. The hand ray needs glasses with a camera macOS can open: the XREAL Aura on firmware 16.1.03 or older. Newer Aura firmware turns the camera off.",
                warn: true
            )
            SettingsDivider()
            SettingsNote("The air trackpad, with a camera that faces you, has not been tried yet either. Lighting and the camera's angle matter: have the light on your hand, not behind it, and turn the camera until your hand sits in the box.")
            SettingsDivider()
            SettingsNote("The camera's light is on while hands are running.")
        }
    }
}

/// What a camera that faces you sees, beside a few words on how to use it. The picture is only asked for while this
/// row is on screen.
struct HandsPreviewRow: View {
    @ObservedObject var prefs: HandsPrefs
    let running: Bool
    @Environment(\.settingsStatic) private var isStatic

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HandsPreviewView(box: prefs.airBox, running: running)
            VStack(alignment: .leading, spacing: 6) {
                Text("What the camera sees")
                    .font(Font.lookLine)
                    .foregroundColor(Color.lookInk)
                Text("As in a mirror. The box is the whole screen: keep your hand inside it. The dot is the spot on your hand that moves the pointer.")
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(running ? "The camera's light is on while hands are running." : "Start hands to see the picture.")
                    .font(Font.lookNote)
                    .foregroundColor(Color.lookInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, 14)
        .onAppear { if !isStatic { HandsPreview.shared.watching = true } }
        .onDisappear {
            HandsPreview.shared.watching = false
            HandsPreview.shared.picture = nil
        }
    }
}

/// The camera's picture, mirrored, with the air trackpad's box and the tracked point drawn on it. With no picture
/// (hands off, or a picture drawn to a file) a plain dark panel with a hand drawn in it.
struct HandsPreviewView: View {
    let box: HandAirBox
    let running: Bool
    @ObservedObject private var preview = HandsPreview.shared
    @Environment(\.settingsStatic) private var isStatic

    private static let width: CGFloat = 216

    var body: some View {
        let picture: CGImage? = isStatic ? nil : preview.picture
        let aspect: CGFloat = picture.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 4.0 / 3
        let size = CGSize(width: Self.width, height: (Self.width / aspect).rounded())
        // In a picture drawn to a file: a hand a little right of the box's middle, as if it were being tracked.
        let point: HandPoint? = isStatic ? HandPoint(x: 0.47, y: 0.55) : preview.point
        return ZStack {
            if let picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            } else {
                LinearGradient(colors: [Look.glassBottom.color, Look.page.color], startPoint: .top, endPoint: .bottom)
                if isStatic || !running {
                    HandsGlyph(kind: .pinch, bare: true, length: 96)
                        .opacity(isStatic ? 0.8 : 0.35)
                        // The drawing's pinch (17.5, 24.5 of 52) is put on the tracked point.
                        .position(
                            x: CGFloat(point?.x ?? 0.5) * size.width + (26 - 17.5) / 52 * 96,
                            y: CGFloat(point?.y ?? 0.5) * size.height + (26 - 24.5) / 52 * 96
                        )
                }
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.lookAccent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: CGFloat(HandAirBox.widthShare) * size.width, height: CGFloat(HandAirBox.heightShare) * size.height)
                .position(x: CGFloat(box.centre.x) * size.width, y: CGFloat(box.centre.y) * size.height)
            if let point {
                ZStack {
                    Circle().fill(Color.lookAccent.opacity(0.3)).frame(width: 18, height: 18)
                    Circle().fill(Color.lookAccent).frame(width: 9, height: 9)
                    Circle().fill(Color.white).frame(width: 3, height: 3)
                }
                .position(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.lookRim, lineWidth: 1))
        .accessibilityLabel(Text("What the camera sees"))
    }
}

/// One of a few choices, as a row: a ring that fills with the accent when chosen, the name, a line under it.
struct HandsChoiceRow: View {
    let title: String
    let note: String
    let selected: Bool
    let action: () -> Void
    @State private var hover: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Color.lookAccent : (hover ? Color.lookRimFocus : Color.white.opacity(0.24)), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(Color.lookAccent)
                        .frame(width: 9, height: 9)
                        .opacity(selected ? 1 : 0)
                    Circle()
                        .strokeBorder(Color.lookAccent, lineWidth: 2)
                        .frame(width: 24, height: 24)
                        .opacity(focused ? 1 : 0)
                }
                .frame(width: 24, height: 24)
                SettingsRowText(title: title, note: note)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.vertical, 10)
            .frame(minHeight: SettingsMetrics.row)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.white.opacity(hover && !selected ? 0.03 : 0))
            .contentShape(Rectangle())
            .animation(Animation.lookEnter(Look.quick), value: selected)
            .animation(Animation.lookEnter(Look.quick), value: hover)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hover = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(note))
        .accessibilityValue(Text(selected ? "Selected" : ""))
    }
}

/// One gesture: its drawing, what to do, what it does.
struct HandsGestureRow: View {
    let glyph: HandsGlyph.Kind
    let title: String
    let note: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HandsGlyph(kind: glyph)
            SettingsRowText(title: title, note: note)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// A small drawing of a hand doing one gesture, on a glass tile: the hand in the ink colour, what matters in the
/// accent (where the pointer is, where the fingers meet, which way a drag goes, the palm, the hold).
struct HandsGlyph: View {
    enum Kind {
        case point, pinch, drag, palmPinch, palmHold
    }

    let kind: Kind
    /// Without the tile, for drawing the hand on something else.
    var bare: Bool = false
    var length: CGFloat = HandsGlyph.side
    nonisolated static let side: CGFloat = 52

    var body: some View {
        Canvas { context, size in
            HandsGlyph.draw(kind, in: &context, size: size)
        }
        .frame(width: length, height: length)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Look.glassTop.color, Look.glassBottom.color], startPoint: .top, endPoint: .bottom))
                .opacity(bare ? 0 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.lookRim, lineWidth: 1)
                .opacity(bare ? 0 : 1)
        )
        .accessibilityHidden(true)
    }

    /// Everything is drawn on a 52 by 52 grid and scaled to [size].
    private nonisolated static func draw(_ kind: Kind, in context: inout GraphicsContext, size: CGSize) {
        let k: CGFloat = min(size.width, size.height) / side
        context.scaleBy(x: k, y: k)
        // Opaque, so the strokes that make up the hand join into one shape with no seams.
        let ink = GraphicsContext.Shading.color(Color(.sRGB, red: 0.90, green: 0.91, blue: 0.93, opacity: 1))
        let accent = GraphicsContext.Shading.color(Color.lookAccent)
        let pinched: Bool = kind != .point
        let palm: Bool = kind == .palmPinch || kind == .palmHold

        // The hand: a palm and five fingers as round ended strokes, one silhouette. A right hand from behind (or a
        // left one from the front): the thumb is on the left. It sits to the right, leaving the left for the marks.
        let finger = StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round)
        let small = StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
        let thumbStyle = StrokeStyle(lineWidth: 5.0, lineCap: .round, lineJoin: .round)
        let palmRect = CGRect(x: 24.5, y: 27, width: 18.5, height: 16.5)
        context.fill(Path(roundedRect: palmRect, cornerRadius: 6.5, style: .continuous), with: ink)

        func line(_ points: [CGPoint]) -> Path {
            var p = Path()
            p.move(to: points[0])
            for q in points.dropFirst() { p.addLine(to: q) }
            return p
        }
        // Middle, ring and little fingers are up in every drawing.
        context.stroke(line([CGPoint(x: 32.2, y: 30), CGPoint(x: 32.2, y: 11.5)]), with: ink, style: finger)
        context.stroke(line([CGPoint(x: 37.4, y: 30), CGPoint(x: 37.6, y: 13.5)]), with: ink, style: finger)
        context.stroke(line([CGPoint(x: 41.6, y: 31), CGPoint(x: 42.4, y: 19)]), with: ink, style: small)

        // Where the thumb and first finger meet in a pinch.
        let meet = CGPoint(x: 17.5, y: 24.5)
        if pinched {
            context.stroke(line([CGPoint(x: 27, y: 30), CGPoint(x: 25.2, y: 19.5), CGPoint(x: 19.3, y: 22.6)]), with: ink, style: finger)
            context.stroke(line([CGPoint(x: 26.5, y: 38.5), CGPoint(x: 19.6, y: 27.2)]), with: ink, style: thumbStyle)
        } else {
            context.stroke(line([CGPoint(x: 27, y: 30), CGPoint(x: 26.6, y: 13.5)]), with: ink, style: finger)
            context.stroke(line([CGPoint(x: 26.5, y: 38.5), CGPoint(x: 18.2, y: 30.5)]), with: ink, style: thumbStyle)
        }

        if palm {
            // The palm is shown: a ring of light in the middle of it.
            let centre = CGPoint(x: palmRect.midX + 0.6, y: palmRect.midY + 0.8)
            let ring = Path(ellipseIn: CGRect(x: centre.x - 4.2, y: centre.y - 4.2, width: 8.4, height: 8.4))
            context.fill(ring, with: .color(Look.card.color))
            context.stroke(ring, with: accent, style: StrokeStyle(lineWidth: 1.8))
        }

        switch kind {
        case .point:
            // The pointer, off where the hand aims, and the line of sight to it.
            let pointer = CGPoint(x: 9.5, y: 12.5)
            context.stroke(
                line([CGPoint(x: 20.5, y: 24.5), CGPoint(x: 12.4, y: 15.6)]),
                with: .color(Color.lookAccent.opacity(0.75)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 3.6])
            )
            halo(&context, at: pointer, radius: 6.2)
            context.fill(Path(ellipseIn: CGRect(x: pointer.x - 3.1, y: pointer.y - 3.1, width: 6.2, height: 6.2)), with: accent)
        case .pinch:
            spark(&context, at: meet)
        case .drag:
            // The pinch, carried to the left.
            let tip = CGPoint(x: 5.5, y: meet.y)
            let shaft = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            context.stroke(line([CGPoint(x: meet.x - 5.5, y: meet.y), tip]), with: accent, style: shaft)
            context.stroke(line([CGPoint(x: tip.x + 3.6, y: tip.y - 3.4), tip, CGPoint(x: tip.x + 3.6, y: tip.y + 3.4)]), with: accent, style: shaft)
            spark(&context, at: meet)
        case .palmPinch:
            spark(&context, at: meet)
        case .palmHold:
            // Held: three quarters of a circle round the pinch, as a clock filling.
            var arc = Path()
            arc.addArc(center: meet, radius: 8.2, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
            context.stroke(arc, with: accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            var rest = Path()
            rest.addArc(center: meet, radius: 8.2, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: false)
            context.stroke(rest, with: .color(Color.white.opacity(0.16)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            spark(&context, at: meet)
        }
    }

    /// The accent's soft light round a mark.
    private nonisolated static func halo(_ context: inout GraphicsContext, at p: CGPoint, radius: CGFloat) {
        context.fill(
            Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(Color.lookAccent.opacity(0.22))
        )
    }

    /// Where the fingers meet: a dot of the accent with its halo.
    private nonisolated static func spark(_ context: inout GraphicsContext, at p: CGPoint) {
        halo(&context, at: p, radius: 5.6)
        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.7, y: p.y - 2.7, width: 5.4, height: 5.4)), with: accent(1))
    }

    private nonisolated static func accent(_ opacity: Double) -> GraphicsContext.Shading {
        .color(Color.lookAccent.opacity(opacity))
    }
}
