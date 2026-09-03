import Foundation

/// The N in "stop after N shots."
///
/// If the app side's `Int?` were passed around as-is, `0` or a negative number
/// (i.e. a value that doesn't make sense as a target) could slip into the check.
/// Reject it at construction time so that **whenever it exists, it's guaranteed valid**.
///
/// The check itself is one line, but it's placed in the kit and pinned down by tests.
/// "Does it stop at exactly shot N?" and "does it also stop if it overshoots?" are
/// boundary cases where a miss means the whole feature doesn't work, and that can't be
/// verified if it's buried in UI-side code.
public struct ShotTarget: Sendable, Hashable, Codable {
    /// The target shot count. Always 1 or greater.
    public let count: Int

    /// Only valid as a target when 1 or greater. `nil` / 0 / negative means "stop manually."
    public init?(_ count: Int?) {
        guard let count, count > 0 else { return nil }
        self.count = count
    }

    /// Whether the session should stop now. **Stops both exactly at and past the target.**
    ///
    /// Overshoot is included because full-auto can't be stopped shot-by-shot: with a
    /// target of 10, holding the trigger down can land 12 shots, and checking only for
    /// "exactly" would mean it never stops.
    public func isReached(shotCount: Int) -> Bool {
        shotCount >= count
    }

    /// Shots remaining. 0 once the target is reached.
    public func remaining(shotCount: Int) -> Int {
        max(0, count - shotCount)
    }

    /// Progress (0...1). Capped at 1 even on overshoot.
    public func progress(shotCount: Int) -> Double {
        guard count > 0 else { return 0 }
        return min(1.0, Double(max(0, shotCount)) / Double(count))
    }
}
