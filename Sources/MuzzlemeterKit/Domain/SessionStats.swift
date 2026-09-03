import Foundation

/// Session statistics computed as a pure value from `[Shot]` and a BB weight.
///
/// Neither persisted nor observed — treated as a derived value that can be rebuilt at any
/// time. The UI side can simply call `compute(shots:massGrams:)` again after every shot
/// (O(n), which is plenty fast at the shot counts this is used for).
public struct SessionStats: Sendable, Hashable, Codable {
    /// Shot count.
    public let count: Int
    /// The BB weight (g) used for the calculation.
    public let massGrams: Double
    /// Mean muzzle velocity (m/s). `nil` for 0 shots.
    public let meanMetersPerSecond: Double?
    /// Max muzzle velocity (m/s).
    public let maxMetersPerSecond: Double?
    /// Min muzzle velocity (m/s).
    public let minMetersPerSecond: Double?
    /// Sample standard deviation (n-1). Undefined below 2 shots, so `nil`.
    public let sampleStandardDeviation: Double?
    /// Extreme spread (max - min).
    public let extremeSpread: Double?
    /// Mean joules per shot.
    public let meanJoules: Double?
    /// Joules at the max velocity.
    public let maxJoules: Double?
    /// Mean of the rate of fire reported by the device (rounds/sec). `nil` if no shot
    /// reported one.
    public let meanRateOfFireRPS: Double?

    public init(
        count: Int,
        massGrams: Double,
        meanMetersPerSecond: Double?,
        maxMetersPerSecond: Double?,
        minMetersPerSecond: Double?,
        sampleStandardDeviation: Double?,
        extremeSpread: Double?,
        meanJoules: Double?,
        maxJoules: Double?,
        meanRateOfFireRPS: Double?
    ) {
        self.count = count
        self.massGrams = massGrams
        self.meanMetersPerSecond = meanMetersPerSecond
        self.maxMetersPerSecond = maxMetersPerSecond
        self.minMetersPerSecond = minMetersPerSecond
        self.sampleStandardDeviation = sampleStandardDeviation
        self.extremeSpread = extremeSpread
        self.meanJoules = meanJoules
        self.maxJoules = maxJoules
        self.meanRateOfFireRPS = meanRateOfFireRPS
    }

    /// Statistics for 0 shots.
    public static func empty(massGrams: Double = 0.20) -> SessionStats {
        SessionStats(
            count: 0,
            massGrams: massGrams,
            meanMetersPerSecond: nil,
            maxMetersPerSecond: nil,
            minMetersPerSecond: nil,
            sampleStandardDeviation: nil,
            extremeSpread: nil,
            meanJoules: nil,
            maxJoules: nil,
            meanRateOfFireRPS: nil
        )
    }

    public var isEmpty: Bool { count == 0 }

    /// Computes statistics from a list of shots.
    ///
    /// - Parameters:
    ///   - shots: the shots to include (order doesn't matter)
    ///   - massGrams: the BB weight (g), used for the joule calculation.
    public static func compute(shots: [Shot], massGrams: Double) -> SessionStats {
        guard !shots.isEmpty else { return .empty(massGrams: massGrams) }

        let velocities = shots.map(\.velocityMetersPerSecond)
        let n = Double(velocities.count)
        let sum = velocities.reduce(0, +)
        let mean = sum / n
        // max/min are already known to be non-empty, so fall back with nil-coalescing
        // instead of force-unwrapping.
        let maxV = velocities.max() ?? mean
        let minV = velocities.min() ?? mean

        // Sample standard deviation (n-1): shooting data is a sample, not a population,
        // so n-1 is used.
        let sd: Double?
        if velocities.count >= 2 {
            let squaredError = velocities.reduce(0.0) { partial, v in
                let d = v - mean
                return partial + d * d
            }
            sd = (squaredError / (n - 1)).squareRoot()
        } else {
            sd = nil
        }

        let joulesSum = velocities.reduce(0.0) { partial, v in
            partial + Energy.joules(massGrams: massGrams, velocityMetersPerSecond: v)
        }

        let reportedROF = shots.compactMap(\.rateOfFireRPS)
        let meanROF: Double? = reportedROF.isEmpty
            ? nil
            : reportedROF.reduce(0, +) / Double(reportedROF.count)

        return SessionStats(
            count: velocities.count,
            massGrams: massGrams,
            meanMetersPerSecond: mean,
            maxMetersPerSecond: maxV,
            minMetersPerSecond: minV,
            sampleStandardDeviation: sd,
            extremeSpread: maxV - minV,
            meanJoules: joulesSum / n,
            maxJoules: Energy.joules(massGrams: massGrams, velocityMetersPerSecond: maxV),
            meanRateOfFireRPS: meanROF
        )
    }
}
