import Foundation

/// A statistic represented by one row of the comparison table.
///
/// This decides both the order of rows in the comparison view and **whether that row has
/// a "better / worse" direction at all**. Burying it in the UI would make it untestable,
/// and would risk each screen getting the meaning wrong in a different way (e.g.
/// "a higher max is better").
public enum ComparisonMetric: String, CaseIterable, Sendable, Hashable, Identifiable, Codable {
    case count
    case mean
    case sampleStandardDeviation
    case extremeSpread
    case max
    case min
    case meanJoules
    case overLimitCount

    public var id: String { rawValue }

    /// Whether the value has a "better/worse" direction.
    ///
    /// **Only "spread" and "shots over the limit" have a direction.** A higher mean or
    /// max isn't necessarily better (it's closer to the regulation limit, so it's often
    /// the opposite), and a higher shot count isn't better either. Marking a metric that
    /// has no real direction would mislead the reader into picking "whichever one is
    /// marked."
    public var preference: ComparisonPreference {
        switch self {
        case .sampleStandardDeviation, .extremeSpread, .overLimitCount: .lower
        case .count, .mean, .max, .min, .meanJoules: .none
        }
    }

    /// The kind of value. Separates display formatting (speed uses the display unit,
    /// joules uses the joule format, shot count is an integer).
    public var kind: ComparisonValueKind {
        switch self {
        case .count, .overLimitCount: .shotCount
        case .mean, .sampleStandardDeviation, .extremeSpread, .max, .min: .speed
        case .meanJoules: .joules
        }
    }

    /// Whether this is a speed "difference." When converting to fps, a difference carries
    /// no offset (SD and ES only apply the ratio, anchored at 0).
    public var isSpeedDifference: Bool {
        self == .sampleStandardDeviation || self == .extremeSpread
    }
}

/// The direction of "better/worse" for a value.
public enum ComparisonPreference: Sendable, Hashable, Codable {
    /// Lower is better (spread, shots over the limit).
    case lower
    /// No direction. Not marked.
    case none
}

public enum ComparisonValueKind: Sendable, Hashable, Codable {
    /// Speed (formatted in the display unit).
    case speed
    /// Energy (J).
    case joules
    /// Shot count (integer).
    case shotCount
}

/// The values for one session in a comparison. **The caller computes the stats once and
/// passes them in.**
///
/// The comparison view reads the same stats repeatedly, once per row and once per chart,
/// so recomputing them inside the view would waste work proportional to the shot count.
public struct ComparisonColumn: Sendable, Hashable, Identifiable {
    public let id: String
    public let stats: SessionStats
    /// The number of shots that exceeded the regulation limit. `SessionStats` doesn't
    /// keep per-shot values, so this is passed in from outside.
    public let overLimitCount: Int

    public init(id: String, stats: SessionStats, overLimitCount: Int) {
        self.id = id
        self.stats = stats
        self.overLimitCount = overLimitCount
    }
}

/// The pure logic that decides what goes in the session comparison table.
public enum ComparisonTable {
    /// The order of rows shown in the table.
    public static let metrics: [ComparisonMetric] = [
        .count, .mean, .sampleStandardDeviation, .extremeSpread,
        .max, .min, .meanJoules, .overLimitCount,
    ]

    /// The values for one row (column order matches `columns`; `nil` where a value isn't
    /// available).
    ///
    /// Speed is returned in m/s as-is. Converting to the display unit is the display
    /// layer's responsibility.
    public static func values(
        of metric: ComparisonMetric,
        columns: [ComparisonColumn]
    ) -> [Double?] {
        columns.map { column in
            switch metric {
            case .count: Double(column.stats.count)
            case .mean: column.stats.meanMetersPerSecond
            case .sampleStandardDeviation: column.stats.sampleStandardDeviation
            case .extremeSpread: column.stats.extremeSpread
            case .max: column.stats.maxMetersPerSecond
            case .min: column.stats.minMetersPerSecond
            case .meanJoules: column.stats.meanJoules
            case .overLimitCount: Double(column.overLimitCount)
            }
        }
    }

    /// The positions of the "best" columns in that row. An empty set when nothing should
    /// be marked.
    ///
    /// - A metric with no direction (mean, max, etc.) is always an empty set.
    /// - A row with only 1 value is an empty set (nothing to compare against, so marking
    ///   it means nothing).
    /// - **All-equal values is an empty set** (if everything is marked, the mark itself
    ///   carries no information).
    /// - A tie returns every tied column (there's no basis for picking just one).
    public static func bestIndices(
        of metric: ComparisonMetric,
        values: [Double?],
        tolerance: Double = 1e-9
    ) -> Set<Int> {
        guard metric.preference == .lower else { return [] }
        let present = values.enumerated().compactMap { index, value in
            value.flatMap { $0.isFinite ? (index: index, value: $0) : nil }
        }
        guard present.count >= 2 else { return [] }
        guard let best = present.map(\.value).min() else { return [] }
        guard let worst = present.map(\.value).max(), worst - best > tolerance else { return [] }
        return Set(present.filter { $0.value - best <= tolerance }.map(\.index))
    }

    /// Computes row -> marked columns for every metric at once.
    public static func bestIndicesByMetric(
        columns: [ComparisonColumn],
        metrics: [ComparisonMetric] = ComparisonTable.metrics
    ) -> [ComparisonMetric: Set<Int>] {
        var result: [ComparisonMetric: Set<Int>] = [:]
        for metric in metrics {
            result[metric] = bestIndices(of: metric, values: values(of: metric, columns: columns))
        }
        return result
    }
}
