import Foundation

/// Where Pocket XR draws the pointer itself on a screen (Quick pointer). The pointer macOS draws comes through screen
/// capture with the rest of the picture, a frame or more late; read at each frame and drawn on the screen's panel, it
/// moves as soon as the mouse does. A developer with an XREAL 1S on a Mac, November 2026: "mouse cursor latency".
public enum PointerSpot {
    /// The pointer's picture on a screen, as a part of the screen's picture: its top left corner and its size, each
    /// 0 to 1 of the screen's width and height (the panel's uv). Nil when the pointer is not on this screen.
    ///
    /// - [pointer]: where the pointer is, in the global points macOS uses for displays (top left origin, y down).
    /// - [screen]: the screen's bounds in the same points (CGDisplayBounds).
    /// - [hotSpot]: the point of the pointer's picture that is at [pointer], from its top left, points.
    /// - [size]: the pointer picture's size, points.
    public static func rect(pointer: (x: Double, y: Double), screen: (x: Double, y: Double, width: Double, height: Double),
                            hotSpot: (x: Double, y: Double), size: (width: Double, height: Double)) -> (u: Double, v: Double, width: Double, height: Double)? {
        guard screen.width > 0, screen.height > 0, size.width > 0, size.height > 0 else { return nil }
        let px = pointer.x - screen.x, py = pointer.y - screen.y
        // macOS keeps the pointer inside a display, its far edge one point short.
        guard px >= 0, py >= 0, px < screen.width, py < screen.height else { return nil }
        return ((px - hotSpot.x) / screen.width, (py - hotSpot.y) / screen.height,
                size.width / screen.width, size.height / screen.height)
    }

    /// Which of [screens] (CGDisplayBounds, in order) the pointer is on, nil for none.
    public static func screen(pointer: (x: Double, y: Double), screens: [(x: Double, y: Double, width: Double, height: Double)]) -> Int? {
        screens.firstIndex { b in
            pointer.x >= b.x && pointer.y >= b.y && pointer.x < b.x + b.width && pointer.y < b.y + b.height
        }
    }
}
