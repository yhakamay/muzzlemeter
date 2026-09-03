import Foundation

/// Fallback estimation of rate of fire (ROF).
///
/// The AC6000 sends `rawRev` (the raw rate-of-fire value) as part of `FIRE_REPORT`, so
/// `Shot.rateOfFireRPS` is normally used directly. What's here is a pure function that
/// estimates ROF from the difference between shot timestamps, for the case **where the
/// device doesn't report ROF, or the reported value can't be decoded yet**.
public enum RateOfFire {
    /// A gap larger than this many seconds is treated as the end of a burst.
    public static let defaultBurstGapThreshold: TimeInterval = 1.0

    /// Estimates the firing rate (rounds/sec) of the most recent burst.
    ///
    /// Walks backward in time from the last shot, treating shots as part of the same
    /// burst as long as the interval to the previous shot is `<= burstGapThreshold`. If
    /// the burst has only 1 shot (i.e. a single shot), a rate can't be defined, so this
    /// returns `nil`.
    ///
    /// - Parameters:
    ///   - shots: the shot list. Order doesn't matter (sorted internally by time).
    ///   - burstGapThreshold: the interval (seconds) treated as the end of a burst.
    public static func estimateRPS(
        shots: [Shot],
        burstGapThreshold: TimeInterval = defaultBurstGapThreshold
    ) -> Double? {
        estimateRPS(timestamps: shots.map(\.timestamp), burstGapThreshold: burstGapThreshold)
    }

    /// Estimates the firing rate (rounds/sec) of the most recent burst from a list of
    /// timestamps.
    public static func estimateRPS(
        timestamps: [Date],
        burstGapThreshold: TimeInterval = defaultBurstGapThreshold
    ) -> Double? {
        let burst = latestBurst(timestamps: timestamps, burstGapThreshold: burstGapThreshold)
        guard burst.count >= 2, let first = burst.first, let last = burst.last else { return nil }
        let duration = last.timeIntervalSince(first)
        guard duration > 0 else { return nil }
        // n shots have n-1 intervals between them.
        return Double(burst.count - 1) / duration
    }

    /// Returns the timestamps belonging to the most recent burst, in ascending order.
    ///
    /// For a single shot, returns an array with 1 element (an empty array for empty input).
    public static func latestBurst(
        timestamps: [Date],
        burstGapThreshold: TimeInterval = defaultBurstGapThreshold
    ) -> [Date] {
        let sorted = timestamps.sorted()
        guard let last = sorted.last else { return [] }

        var burst: [Date] = [last]
        var index = sorted.count - 2
        while index >= 0 {
            let gap = burst[0].timeIntervalSince(sorted[index])
            guard gap <= burstGapThreshold else { break }
            burst.insert(sorted[index], at: 0)
            index -= 1
        }
        return burst
    }
}
