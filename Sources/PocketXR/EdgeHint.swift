import AppKit
import PocketXRCore
import SwiftUI

/// A small lit tab on the right edge of the Mac's screen that says where the floating screens are: past that edge.
/// Clicks go through it, and it goes away for the session once the pointer has been across.
@MainActor
final class EdgeHint {
    private var panel: NSPanel?
    private static let size = NSSize(width: 236, height: 52)

    func show(onRightEdgeOf screen: NSScreen) {
        let p: NSPanel = panel ?? make()
        panel = p
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.maxX - Self.size.width, y: area.midY - Self.size.height / 2)
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: EdgeHintView())
        return p
    }
}

private struct EdgeHintView: View {
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced)) { time in
            let t = time.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                Text("Floating screens")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                HStack(spacing: 1) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.lookAccent)
                            .opacity(reduced ? 1 : chevron(t, i))
                    }
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 26, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                    .fill(Color.lookCard.opacity(0.94))
            )
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 26, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                    .stroke(Color.lookAccent.opacity(0.55), lineWidth: 1)
            )
        }
        .accessibilityLabel("Your floating screens are past the right edge of this screen")
    }

    /// Three chevrons lit one after the other, left to right, every 1.4 s: a quiet "this way".
    private func chevron(_ t: Double, _ i: Int) -> Double {
        let phase = (t / 1.4).truncatingRemainder(dividingBy: 1) * 3 - Double(i)
        let near = max(0, 1 - abs(phase - 0.5) * 1.4)
        return 0.3 + 0.7 * near
    }
}
