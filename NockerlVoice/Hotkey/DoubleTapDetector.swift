import Foundation

/// Detects a double-tap from a stream of taps: two taps no more than `window`
/// apart. Pure logic so it can be unit-tested without the event tap. The first of
/// a pair returns false; the second (if in time) returns true and consumes the
/// pair.
struct DoubleTapDetector {
    let window: TimeInterval
    private var lastTap: TimeInterval?

    init(window: TimeInterval = 0.35) {
        self.window = window
    }

    /// Register a tap at monotonic time `t`. Returns true iff it completes a double-tap.
    mutating func registerTap(at t: TimeInterval) -> Bool {
        if let last = lastTap, t >= last, t - last <= window {
            lastTap = nil          // consume the pair
            return true
        }
        lastTap = t
        return false
    }

    mutating func reset() {
        lastTap = nil
    }
}
