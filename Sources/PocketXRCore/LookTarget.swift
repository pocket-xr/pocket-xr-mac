import Foundation

/// Which screen the head points at, for moving the pointer to the screen you look at and lighting it.
public enum LookTarget {
    /// The screen the head points at: the index in [panels] and where on it (u, v 0...1 from the top left), or nil
    /// if the head's forward ray misses every screen. [head] is the drawn pose; forward is -z. A curved screen is
    /// met on its cylinder, so it counts by its angular extent as seen from the head. Where screens overlap, the
    /// nearest one wins.
    public static func hit(head: Quat, panels: [PanelPlacement]) -> (index: Int, u: Double, v: Double)? {
        let forward = head.rotate(SIMD3<Double>(0, 0, -1))
        var best: (index: Int, u: Double, v: Double)? = nil
        var bestT = Double.infinity
        for (i, p) in panels.enumerated() {
            guard let h = PanelCurve.intersect(p, direction: forward) else { continue }
            if abs(h.x) > 0.5 || abs(h.y) > 0.5 { continue }
            if h.t < bestT {
                bestT = h.t
                best = (index: i, u: h.x + 0.5, v: 0.5 - h.y)
            }
        }
        return best
    }
}
