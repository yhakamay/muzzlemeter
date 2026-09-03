import Foundation

/// The input for one session used to build a trend. **The caller computes the stats and
/// passes them in.**
///
/// Per-session stats are used both in the session detail view and the comparison view.
/// Recomputing them from `[Shot]` here would repeat the same calculation in every screen.
public struct ProfileTrendSample: Sendable, Hashable {
    /// An opaque identifier letting the caller navigate back to the session.
    public let id: String
    public let date: Date
    public let massGrams: Double
    /// The effective temperature (manual ?? auto). `nil` if not recorded.
    public let temperatureC: Double?
    public let stats: SessionStats

    public init(
        id: String,
        date: Date,
        massGrams: Double,
        temperatureC: Double?,
        stats: SessionStats
    ) {
        self.id = id
        self.date = date
        self.massGrams = massGrams
        self.temperatureC = temperatureC
        self.stats = stats
    }
}

/// One point plotted on the chart (= one session).
public struct ProfileTrendPoint: Sendable, Hashable, Identifiable {
    public let id: String
    public let date: Date
    public let massGrams: Double
    public let temperatureC: Double?
    public let count: Int
    public let meanMetersPerSecond: Double
    /// Sample SD. `nil` for a session with only 1 shot (no error bar is drawn).
    public let sampleStandardDeviation: Double?

    public init(
        id: String,
        date: Date,
        massGrams: Double,
        temperatureC: Double?,
        count: Int,
        meanMetersPerSecond: Double,
        sampleStandardDeviation: Double?
    ) {
        self.id = id
        self.date = date
        self.massGrams = massGrams
        self.temperatureC = temperatureC
        self.count = count
        self.meanMetersPerSecond = meanMetersPerSecond
        self.sampleStandardDeviation = sampleStandardDeviation
    }

    /// The lower end of the error bar (mean - SD). The mean itself if there's no SD.
    public var lowerMetersPerSecond: Double {
        meanMetersPerSecond - (sampleStandardDeviation ?? 0)
    }

    /// The upper end of the error bar (mean + SD).
    public var upperMetersPerSecond: Double {
        meanMetersPerSecond + (sampleStandardDeviation ?? 0)
    }
}

/// A summary across the whole profile.
public struct ProfileTrendSummary: Sendable, Hashable {
    /// The session count (**counts sessions with 0 shots too**, since this is a record of
    /// how many times the gun was picked up).
    public let sessionCount: Int
    /// Total shot count.
    public let shotCount: Int
    /// The date of the last shot. `nil` if there are none.
    public let lastSessionDate: Date?
    /// The mean (m/s) when all shots are treated as one sample.
    public let meanMetersPerSecond: Double?
    /// The sample SD (n-1) when all shots are treated as one sample.
    public let sampleStandardDeviation: Double?

    public init(
        sessionCount: Int,
        shotCount: Int,
        lastSessionDate: Date?,
        meanMetersPerSecond: Double?,
        sampleStandardDeviation: Double?
    ) {
        self.sessionCount = sessionCount
        self.shotCount = shotCount
        self.lastSessionDate = lastSessionDate
        self.meanMetersPerSecond = meanMetersPerSecond
        self.sampleStandardDeviation = sampleStandardDeviation
    }

    public static let empty = ProfileTrendSummary(
        sessionCount: 0,
        shotCount: 0,
        lastSessionDate: nil,
        meanMetersPerSecond: nil,
        sampleStandardDeviation: nil
    )
}

/// The pure logic that builds a profile's trend (the time series of mean velocity, and
/// its relationship to temperature).
public enum ProfileTrend {
    /// The minimum number of points needed for a scatter plot to mean anything.
    ///
    /// Two points can always be joined by a straight line, which would read as "it gets
    /// faster as temperature rises." Below 3 points, a disclaimer is attached instead.
    public static let minimumTemperaturePoints = 3

    /// The time-series points. **Sessions with 0 shots are dropped** (a point with no
    /// mean can't be plotted). Ordered oldest first (matching the chart's x-axis
    /// direction).
    public static func points(from samples: [ProfileTrendSample]) -> [ProfileTrendPoint] {
        samples
            .compactMap { sample in
                guard let mean = sample.stats.meanMetersPerSecond, sample.stats.count > 0 else {
                    return nil
                }
                return ProfileTrendPoint(
                    id: sample.id,
                    date: sample.date,
                    massGrams: sample.massGrams,
                    temperatureC: sample.temperatureC,
                    count: sample.stats.count,
                    meanMetersPerSecond: mean,
                    sampleStandardDeviation: sample.stats.sampleStandardDeviation
                )
            }
            .sorted { $0.date < $1.date }
    }

    /// Only the points that have a recorded temperature.
    public static func temperaturePoints(_ points: [ProfileTrendPoint]) -> [ProfileTrendPoint] {
        points.filter { $0.temperatureC != nil }
    }

    /// Whether the BB weight varies across sessions. If it does, distinguishing by color
    /// is meaningful.
    public static func massGramsVaries(_ points: [ProfileTrendPoint]) -> Bool {
        guard let first = points.first else { return false }
        // Differences under 0.001 g can't be told apart at the display precision (2
        // decimal digits), so they're treated as the same.
        return points.contains { abs($0.massGrams - first.massGrams) > 0.001 }
    }

    /// The BB weights that appear, lightest first. Used for the legend order.
    public static func massGramsValues(_ points: [ProfileTrendPoint]) -> [Double] {
        var seen: [Double] = []
        for point in points where !seen.contains(where: { abs($0 - point.massGrams) <= 0.001 }) {
            seen.append(point.massGrams)
        }
        return seen.sorted()
    }

    /// The overall summary.
    ///
    /// The mean is weighted by shot count; the SD is the **sample SD when all shots are
    /// treated as one sample**. Averaging the per-session SDs would be wrong (it drops
    /// the variance *between* sessions). This uses the following decomposition directly:
    ///
    ///     (N-1)*s^2 = sum((n_i-1)*s_i^2) + sum(n_i*(m_i-M)^2)
    public static func summary(from samples: [ProfileTrendSample]) -> ProfileTrendSummary {
        guard !samples.isEmpty else { return .empty }
        let lastDate = samples.map(\.date).max()
        let shotCount = samples.reduce(0) { $0 + $1.stats.count }
        guard shotCount > 0 else {
            return ProfileTrendSummary(
                sessionCount: samples.count,
                shotCount: 0,
                lastSessionDate: lastDate,
                meanMetersPerSecond: nil,
                sampleStandardDeviation: nil
            )
        }

        let weightedSum = samples.reduce(0.0) { partial, sample in
            partial + (sample.stats.meanMetersPerSecond ?? 0) * Double(sample.stats.count)
        }
        let mean = weightedSum / Double(shotCount)

        var sd: Double?
        if shotCount >= 2 {
            let squares = samples.reduce(0.0) { partial, sample in
                let n = Double(sample.stats.count)
                guard n > 0, let m = sample.stats.meanMetersPerSecond else { return partial }
                let within = (sample.stats.sampleStandardDeviation ?? 0)
                let betweenDelta = m - mean
                return partial + (n - 1) * within * within + n * betweenDelta * betweenDelta
            }
            sd = (squares / Double(shotCount - 1)).squareRoot()
        }

        return ProfileTrendSummary(
            sessionCount: samples.count,
            shotCount: shotCount,
            lastSessionDate: lastDate,
            meanMetersPerSecond: mean,
            sampleStandardDeviation: sd
        )
    }

    /// The point nearest to the given date. Used for hit-testing when the chart is tapped.
    public static func nearestPoint(to date: Date, in points: [ProfileTrendPoint]) -> ProfileTrendPoint? {
        points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
}
