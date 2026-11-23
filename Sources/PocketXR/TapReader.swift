import Foundation
import PocketXRCore

/// Feeds every head tracking sample to GlassesTaps while "Taps on the glasses" is on. Samples come on the motion
/// reader's thread; [onTaps] is called on the main thread with 2 or 3.
final class TapReader: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = GlassesTaps()
    private var on = false
    var onTaps: (@MainActor (Int) -> Void)?

    /// Switched from the main thread; turning it on starts with a fresh detector.
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set {
            lock.lock()
            if newValue != on { detector.reset() }
            on = newValue
            lock.unlock()
        }
    }

    /// A new stream of samples (the glasses came, or tracking started again): forget the old one.
    func restart() {
        lock.lock()
        detector.reset()
        lock.unlock()
    }

    func feed(_ s: ImuSample) {
        lock.lock()
        guard on else { lock.unlock(); return }
        let n = detector.feed(t: Double(s.timestampNs) / 1e9, gyro: s.gyro, accel: s.accel)
        lock.unlock()
        guard let n, let call = onTaps else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { call(n) } }
    }
}
