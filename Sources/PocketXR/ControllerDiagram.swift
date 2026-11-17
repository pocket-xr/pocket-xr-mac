import PocketXRCore
import SwiftUI

/// A picture of a controller with every control labelled by what it does to the Space, to be learnt in one look.
/// The controller is a plain one of no maker; controls are named by where they sit, as the letters differ by maker.
/// Drawn in a fixed 588 by 262 space and scaled to the width it is given.
struct ControllerDiagram: View {
    let mode: ControllerMode

    private static let design = CGSize(width: 588, height: 262)
    /// The controller's top left corner in the picture; it is 220 wide and 150 tall.
    private static let origin = CGPoint(x: 184, y: 66)
    private static let bodyWidth: CGFloat = 220

    private static let titleFont = Font.system(size: 12.5, weight: .medium)
    private static let subFont = Font.system(size: 11, weight: .regular)
    private static let leader = Color.white.opacity(0.26)

    var body: some View {
        let chosen: ControllerMode = mode
        return Canvas { context, size in
            let k: CGFloat = size.width / Self.design.width
            context.scaleBy(x: k, y: k)
            Self.drawController(&context, mode: chosen)
            Self.drawLabels(&context, mode: chosen)
        }
        .aspectRatio(Self.design.width / Self.design.height, contentMode: .fit)
        .frame(maxWidth: 660)
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(chosen == .off ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("What each control does"))
        .accessibilityValue(Text(Self.spoken(chosen)))
    }

    /// The same as the picture, in words.
    static func spoken(_ mode: ControllerMode) -> String {
        var lines = [String]()
        switch mode {
        case .off: lines.append("The controller is off for Pocket XR.")
        case .held: lines.append("While the left stick is held in:")
        case .always: break
        }
        lines.append("Right stick: move the screens.")
        lines.append("Right trigger: bigger. Left trigger: smaller.")
        lines.append("D-pad up and down: further and nearer. D-pad left and right: less curve and more curve.")
        lines.append("Bottom button: Recentre. Right button: next layout. Left button: Steady mode. Top button: launcher.")
        lines.append("Right bumper: pointer to the next screen. Left bumper: pointer to the previous screen.")
        lines.append("Menu or Options: control panel.")
        return lines.joined(separator: " ")
    }

    // MARK: places

    /// A point of the controller (0...220 across, 0...150 down) as a point of the picture.
    private static func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x, y: origin.y + y)
    }

    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin.x + x, y: origin.y + y, width: w, height: h)
    }

    private static func disc(_ centre: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    private static let dpad = CGPoint(x: 50, y: 52)
    private static let face = CGPoint(x: 170, y: 52)
    private static let leftStick = CGPoint(x: 80, y: 84)
    private static let rightStick = CGPoint(x: 140, y: 84)
    private static let menu = CGPoint(x: 110, y: 40)

    /// The outline: a rounded body with two grips.
    private static func outline() -> Path {
        var p = Path()
        p.move(to: at(50, 12))
        p.addLine(to: at(170, 12))
        p.addCurve(to: at(208, 40), control1: at(194, 12), control2: at(203, 22))
        p.addCurve(to: at(218, 118), control1: at(214, 62), control2: at(220, 96))
        p.addCurve(to: at(190, 148), control1: at(218, 140), control2: at(204, 150))
        p.addCurve(to: at(150, 112), control1: at(176, 146), control2: at(168, 112))
        p.addLine(to: at(70, 112))
        p.addCurve(to: at(30, 148), control1: at(52, 112), control2: at(44, 146))
        p.addCurve(to: at(2, 118), control1: at(16, 150), control2: at(2, 140))
        p.addCurve(to: at(12, 40), control1: at(0, 96), control2: at(6, 62))
        p.addCurve(to: at(50, 12), control1: at(17, 22), control2: at(26, 12))
        p.closeSubpath()
        return p
    }

    // MARK: the controller

    private static func drawController(_ context: inout GraphicsContext, mode: ControllerMode) {
        let rim = Color.white.opacity(0.30)
        let part = Color.white.opacity(0.17)

        // Behind the body: the triggers, then the bumpers in front of them.
        for x in [CGFloat(36), bodyWidth - 36 - 34] {
            let trigger = Path(roundedRect: box(x, -10, 34, 30), cornerRadius: 8, style: .continuous)
            context.fill(trigger, with: .color(Look.glassBottom.color))
            context.stroke(trigger, with: .color(rim), lineWidth: 1)
        }
        for x in [CGFloat(26), bodyWidth - 26 - 54] {
            let bumper = Path(roundedRect: box(x, 3, 54, 24), cornerRadius: 9, style: .continuous)
            context.fill(bumper, with: .color(Look.control.color))
            context.stroke(bumper, with: .color(rim), lineWidth: 1)
        }

        let shape: Path = outline()
        let glass = Gradient(colors: [Look.glassTop.color, Look.glassBottom.color])
        context.fill(shape, with: .linearGradient(glass, startPoint: at(0, 12), endPoint: at(0, 150)))
        context.stroke(shape, with: .color(rim), lineWidth: 1.25)

        // The D-pad: a cross.
        let d: CGPoint = at(dpad.x, dpad.y)
        var cross = Path()
        cross.addRoundedRect(in: CGRect(x: d.x - 5.5, y: d.y - 15, width: 11, height: 30), cornerSize: CGSize(width: 3, height: 3))
        cross.addRoundedRect(in: CGRect(x: d.x - 15, y: d.y - 5.5, width: 30, height: 11), cornerSize: CGSize(width: 3, height: 3))
        context.fill(cross, with: .color(part))

        // The four face buttons.
        let f: CGPoint = at(face.x, face.y)
        for offset in [CGSize(width: 0, height: -13), CGSize(width: 13, height: 0), CGSize(width: 0, height: 13), CGSize(width: -13, height: 0)] {
            context.fill(disc(CGPoint(x: f.x + offset.width, y: f.y + offset.height), 6.5), with: .color(part))
        }

        // Menu.
        let m: CGPoint = at(menu.x, menu.y)
        let pill = Path(roundedRect: CGRect(x: m.x - 7, y: m.y - 3, width: 14, height: 6), cornerRadius: 3, style: .continuous)
        context.fill(pill, with: .color(part))

        // The sticks. In "while holding" the left one is the key to the rest, so it wears the held light.
        let held: Bool = mode == .held
        for (index, stick) in [leftStick, rightStick].enumerated() {
            let c: CGPoint = at(stick.x, stick.y)
            let lit: Bool = held && index == 0
            if lit {
                context.fill(disc(c, 20), with: .color(Color.lookAccent.opacity(0.22)))
            }
            context.fill(disc(c, 14), with: .color(Color.lookPage.opacity(0.75)))
            context.stroke(disc(c, 14), with: .color(lit ? Color.lookHeld : rim), lineWidth: lit ? 1.5 : 1)
            context.fill(disc(c, 9), with: .color(lit ? Color.lookHeld : Color.white.opacity(0.24)))
        }
    }

    // MARK: the labels

    private static func line(_ context: inout GraphicsContext, _ points: [CGPoint], dot: Bool = true) {
        guard let first = points.first, let last = points.last else { return }
        var p = Path()
        p.move(to: first)
        for point in points.dropFirst() { p.addLine(to: point) }
        context.stroke(p, with: .color(leader), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        if dot {
            context.fill(disc(last, 4.5), with: .color(Color.lookAccent.opacity(0.25)))
            context.fill(disc(last, 2.5), with: .color(Color.lookAccent))
        }
    }

    /// Two lines of words: what it does, and under it the control's name. [y] is the middle of the pair.
    private static func label(_ context: inout GraphicsContext, _ title: String, _ sub: String, x: CGFloat, y: CGFloat,
                              anchor: UnitPoint, strong: Bool = false) {
        let top = Text(title).font(titleFont).foregroundColor(strong ? Color.lookHeld : Color.lookInk)
        let bottom = Text(sub).font(subFont).foregroundColor(Color.lookInk3)
        context.draw(top, at: CGPoint(x: x, y: y - 7), anchor: anchor)
        context.draw(bottom, at: CGPoint(x: x, y: y + 8), anchor: anchor)
    }

    /// Four dots as the face buttons sit, one lit: which button a row is about.
    private static func faceGlyph(_ context: inout GraphicsContext, centre: CGPoint, lit: Int) {
        let offsets: [CGSize] = [CGSize(width: 0, height: -5), CGSize(width: 5, height: 0), CGSize(width: 0, height: 5), CGSize(width: -5, height: 0)]
        for (index, offset) in offsets.enumerated() {
            let c = CGPoint(x: centre.x + offset.width, y: centre.y + offset.height)
            if index == lit {
                context.fill(disc(c, 3), with: .color(Color.lookHeld))
            } else {
                context.fill(disc(c, 2.2), with: .color(Color.white.opacity(0.24)))
            }
        }
    }

    private static func drawLabels(_ context: inout GraphicsContext, mode: ControllerMode) {
        let leftText: CGFloat = 150
        let leftLine: CGFloat = 158
        let rightLine: CGFloat = design.width - leftLine
        let rightText: CGFloat = design.width - leftText

        // The triggers: up and over.
        let leftTrigger: CGFloat = origin.x + 53
        let rightTrigger: CGFloat = origin.x + bodyWidth - 53
        line(&context, [CGPoint(x: leftLine, y: 30), CGPoint(x: leftTrigger, y: 30), CGPoint(x: leftTrigger, y: origin.y - 5)])
        label(&context, "Smaller", "Left trigger", x: leftText, y: 30, anchor: .trailing)
        line(&context, [CGPoint(x: rightLine, y: 30), CGPoint(x: rightTrigger, y: 30), CGPoint(x: rightTrigger, y: origin.y - 5)])
        label(&context, "Bigger", "Right trigger", x: rightText, y: 30, anchor: .leading)

        // The bumpers: straight across.
        let bumperY: CGFloat = origin.y + 9
        line(&context, [CGPoint(x: leftLine, y: bumperY), CGPoint(x: origin.x + 31, y: bumperY)])
        label(&context, "Pointer: previous screen", "Left bumper", x: leftText, y: bumperY, anchor: .trailing)
        line(&context, [CGPoint(x: rightLine, y: bumperY), CGPoint(x: origin.x + bodyWidth - 31, y: bumperY)])
        label(&context, "Pointer: next screen", "Right bumper", x: rightText, y: bumperY, anchor: .leading)

        // The D-pad: two pairs of words beside a bar.
        let midY: CGFloat = origin.y + dpad.y
        line(&context, [CGPoint(x: leftLine, y: midY - 22), CGPoint(x: leftLine, y: midY + 44)], dot: false)
        line(&context, [CGPoint(x: leftLine, y: midY), CGPoint(x: origin.x + dpad.x - 17, y: midY)])
        label(&context, "Further, nearer", "D-pad up, down", x: leftText, y: midY - 7, anchor: .trailing)
        label(&context, "Less curve, more curve", "D-pad left, right", x: leftText, y: midY + 29, anchor: .trailing)

        // The face buttons: four rows beside a bar, each with the button's place lit.
        line(&context, [CGPoint(x: rightLine, y: midY - 22), CGPoint(x: rightLine, y: midY + 52)], dot: false)
        line(&context, [CGPoint(x: rightLine, y: midY), CGPoint(x: origin.x + face.x + 22, y: midY)])
        let rows: [String] = ["Launcher", "Next layout", "Recentre", "Steady mode"]
        for (index, title) in rows.enumerated() {
            let y: CGFloat = midY - 12 + CGFloat(index) * 18
            faceGlyph(&context, centre: CGPoint(x: rightText + 8, y: y), lit: index)
            context.draw(Text(title).font(titleFont).foregroundColor(Color.lookInk), at: CGPoint(x: rightText + 24, y: y), anchor: .leading)
        }

        // Menu: straight up to the top.
        let menuX: CGFloat = origin.x + menu.x
        line(&context, [CGPoint(x: menuX, y: 40), CGPoint(x: menuX, y: origin.y + menu.y - 5)])
        label(&context, "Control panel", "Menu or Options", x: menuX, y: 20, anchor: .center)

        // The sticks: straight down, between the grips.
        let stickTop: CGFloat = origin.y + leftStick.y + 16
        let leftX: CGFloat = origin.x + leftStick.x
        let rightX: CGFloat = origin.x + rightStick.x
        line(&context, [CGPoint(x: leftX, y: 226), CGPoint(x: leftX, y: stickTop)], dot: false)
        line(&context, [CGPoint(x: rightX, y: 226), CGPoint(x: rightX, y: stickTop)], dot: false)
        switch mode {
        case .held:
            label(&context, "Hold in for these controls", "Left stick", x: leftX + 6, y: 242, anchor: .trailing, strong: true)
        case .always, .off:
            label(&context, "Nothing to hold", "Left stick", x: leftX + 6, y: 242, anchor: .trailing)
        }
        label(&context, "Move the screens", "Right stick", x: rightX - 6, y: 242, anchor: .leading)
    }
}
