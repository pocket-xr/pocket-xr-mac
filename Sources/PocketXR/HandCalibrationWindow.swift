import AppKit
import PocketXRCore
import SwiftUI

// The hand aim's calibration: five dots, one at a time, over the whole of a floating screen. The person holds a
// hand over each dot and pinches. Dark and plain, so the dot is the only light.

/// Which dot is being asked for; the window's view follows it.
final class HandCalibrationModel: ObservableObject {
    @Published var step = 0
}

/// A borderless window over the whole of one floating screen, in front of everything on it. It never takes the
/// keyboard, and its Cancel can be clicked without making Pocket XR the front app.
@MainActor
final class HandCalibrationWindow {
    private let panel: NSPanel
    private let model = HandCalibrationModel()

    init(screen: NSScreen, onCancel: @escaping () -> Void) {
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        panel.level = .statusBar
        panel.isOpaque = true
        panel.backgroundColor = NSColor(cgColor: Look.page.cgColor) ?? .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: HandCalibrationHost(model: model, onCancel: onCancel).environment(\.colorScheme, .dark))
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Shows the window (the first time) with dot [step] lit, 0 for the first.
    func show(step: Int) {
        model.step = step
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Look.enter
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(Look.easeEnter.0), Float(Look.easeEnter.1), Float(Look.easeEnter.2), Float(Look.easeEnter.3))
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        panel.orderOut(nil)
    }
}

struct HandCalibrationHost: View {
    @ObservedObject var model: HandCalibrationModel
    let onCancel: () -> Void

    var body: some View {
        HandCalibrationView(step: model.step, onCancel: onCancel)
    }
}

/// The calibration's picture: every size is a share of the screen's height, so it looks the same on any screen.
struct HandCalibrationView: View {
    /// The dot being asked for, 0 for the first.
    let step: Int
    let onCancel: () -> Void
    @Environment(\.settingsStatic) private var isStatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing: Bool = false
    @State private var cancelHover: Bool = false

    private var total: Int { HandCalibrationRun.dots.count }

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let h: CGFloat = geo.size.height
            // 1 at 1080 high.
            let unit: CGFloat = max(min(w / 1920, h / 1080), 0.4)
            ZStack {
                Color.lookPage
                glow(w: w, h: h, unit: unit)
                ForEach(0..<total, id: \.self) { i in
                    dot(i, unit: unit)
                        .position(x: CGFloat(HandCalibrationRun.dots[i].u) * w, y: CGFloat(HandCalibrationRun.dots[i].v) * h)
                }
                words(unit: unit)
                    .frame(width: w * 0.44)
                    // Between the upper dots and above the middle one, clear of all five.
                    .position(x: w / 2, y: h * 0.29)
                cancel(unit: unit)
                    .position(x: w / 2, y: h * 0.86)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .background(Color.lookPage)
        .onAppear {
            guard !isStatic, !reduceMotion else { return }
            withAnimation(Animation.lookInOut(1.4).repeatForever(autoreverses: true)) { breathing = true }
        }
    }

    /// A soft pool of the accent's light behind the lit dot, so the eye finds it at once.
    private func glow(w: CGFloat, h: CGFloat, unit: CGFloat) -> some View {
        let at = HandCalibrationRun.dots[min(max(step, 0), total - 1)]
        let centre = UnitPoint(x: CGFloat(at.u), y: CGFloat(at.v))
        return RadialGradient(
            colors: [Color.lookAccent.opacity(0.16), Color.lookAccent.opacity(0.0)],
            center: centre,
            startRadius: 0,
            endRadius: 300 * unit
        )
        .animation(Animation.lookEnter(), value: step)
    }

    @ViewBuilder
    private func dot(_ i: Int, unit: CGFloat) -> some View {
        if i == step {
            ZStack {
                Circle()
                    .strokeBorder(Color.lookAccent.opacity(0.35), lineWidth: 1.5 * unit)
                    .frame(width: 92 * unit, height: 92 * unit)
                    .scaleEffect(breathing ? 1.12 : 1)
                    .opacity(breathing ? 0.5 : 1)
                Circle()
                    .strokeBorder(Color.lookHeld.opacity(0.8), lineWidth: 2 * unit)
                    .frame(width: 56 * unit, height: 56 * unit)
                Circle()
                    .fill(Color.lookAccent)
                    .frame(width: 26 * unit, height: 26 * unit)
                Circle()
                    .fill(Color.white)
                    .frame(width: 7 * unit, height: 7 * unit)
            }
            .accessibilityLabel(Text("Dot \(i + 1) of \(total)"))
        } else if i < step {
            // Done: a quiet tick where the dot was.
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 34 * unit, height: 34 * unit)
                Image(systemName: "checkmark")
                    .font(Font.system(size: 15 * unit, weight: .semibold))
                    .foregroundColor(Color.lookInk3)
            }
            .accessibilityHidden(true)
        } else {
            // Still to come: a faint ring, so the next place to look is no surprise.
            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1.5 * unit)
                .frame(width: 22 * unit, height: 22 * unit)
                .accessibilityHidden(true)
        }
    }

    private func words(unit: CGFloat) -> some View {
        VStack(spacing: 14 * unit) {
            Text("Point at the dot and pinch")
                .font(Font.system(size: 40 * unit, weight: .medium))
                .foregroundColor(Color.lookInk)
            HStack(spacing: 10 * unit) {
                HStack(spacing: 7 * unit) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule()
                            .fill(i < step ? Color.lookAccent.opacity(0.45) : (i == step ? Color.lookAccent : Color.white.opacity(0.16)))
                            .frame(width: (i == step ? 30 : 14) * unit, height: 6 * unit)
                    }
                }
                Text("\(min(step + 1, total)) of \(total)")
                    .font(Font.system(size: 20 * unit, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.lookInk2)
            }
            Text("Hold your hand so it covers the dot, then touch thumb and first finger together. Go by your hand, not by the pointer: the pointer may be off until this is done.")
                .font(Font.system(size: 20 * unit, weight: .regular))
                .foregroundColor(Color.lookInk2)
                .multilineTextAlignment(.center)
                .lineSpacing(4 * unit)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6 * unit)
        }
        .accessibilityElement(children: .combine)
    }

    private func cancel(unit: CGFloat) -> some View {
        VStack(spacing: 12 * unit) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(Font.system(size: 20 * unit, weight: .medium))
                    .foregroundColor(Color.lookInk)
                    .padding(.horizontal, 30 * unit)
                    .frame(height: 48 * unit)
                    .background(Capsule().fill(cancelHover ? Color.lookGlassHover : Look.control.color.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(cancelHover ? Color.lookRimFocus : Color.lookRim, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(SettingsPressStyle())
            .focusEffectDisabled()
            .onHover { cancelHover = $0 }
            Text("Click Cancel with the trackpad. It also stops by itself after 30 seconds without a pinch.")
                .font(Font.system(size: 16 * unit, weight: .regular))
                .foregroundColor(Color.lookInk3)
        }
    }
}
