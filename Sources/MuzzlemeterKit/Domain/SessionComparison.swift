import Foundation

/// 比較表の 1 行が表す統計項目。
///
/// 比較画面の行の並びと、**その行に「良い / 悪い」があるかどうか**をここで決める。
/// UI に埋めるとテストできないうえ、「最大が速いほうが良い」のような
/// 意味の取り違えが画面ごとに起きるため。
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

    /// 値の良し悪しに向きがあるか。
    ///
    /// **向きがあるのは「ばらつき」と「超過発数」だけ**にしてある。平均や最大が
    /// 速いほうが良いとは限らない（規制上限に近づくのだから、むしろ逆のことも多い）し、
    /// 発数が多いほうが良いわけでもない。意味の無い印を付けると、
    /// 「印が付いているほうを選べばよい」と誤読させてしまう。
    public var preference: ComparisonPreference {
        switch self {
        case .sampleStandardDeviation, .extremeSpread, .overLimitCount: .lower
        case .count, .mean, .max, .min, .meanJoules: .none
        }
    }

    /// 値の種類。表示の整形（速度は表示単位、J はジュール書式、発数は整数）を分ける。
    public var kind: ComparisonValueKind {
        switch self {
        case .count, .overLimitCount: .shotCount
        case .mean, .sampleStandardDeviation, .extremeSpread, .max, .min: .speed
        case .meanJoules: .joules
        }
    }

    /// 速度の「差」かどうか。fps へ換算するとき、差はオフセットを持たない
    /// （SD と ES は 0 を基準にした比率だけを掛ける）。
    public var isSpeedDifference: Bool {
        self == .sampleStandardDeviation || self == .extremeSpread
    }
}

/// 値の良し悪しの向き。
public enum ComparisonPreference: Sendable, Hashable, Codable {
    /// 小さいほうが良い（ばらつき・超過発数）。
    case lower
    /// 良し悪しが決まらない。印を付けない。
    case none
}

public enum ComparisonValueKind: Sendable, Hashable, Codable {
    /// 速度（表示単位で整形する）。
    case speed
    /// エネルギー（J）。
    case joules
    /// 発数（整数）。
    case shotCount
}

/// 比較する 1 セッション分の値。**統計は呼び出し側で 1 回だけ計算して渡す**。
///
/// 比較画面は行ごと・チャートごとに同じ統計を何度も読むので、ビューの中で
/// 計算し直すと発数に比例して無駄が増える。
public struct ComparisonColumn: Sendable, Hashable, Identifiable {
    public let id: String
    public let stats: SessionStats
    /// 規制上限を越えた発数。`SessionStats` は 1 発ごとの値を持たないので外から渡す。
    public let overLimitCount: Int

    public init(id: String, stats: SessionStats, overLimitCount: Int) {
        self.id = id
        self.stats = stats
        self.overLimitCount = overLimitCount
    }
}

/// セッション比較表の中身を決める純粋なロジック。
public enum ComparisonTable {
    /// 表に出す行の並び。
    public static let metrics: [ComparisonMetric] = [
        .count, .mean, .sampleStandardDeviation, .extremeSpread,
        .max, .min, .meanJoules, .overLimitCount,
    ]

    /// 1 行分の値（列の並びは `columns` と同じ。取れない値は `nil`）。
    ///
    /// 速度は m/s のまま返す。表示単位への換算は表示側の責任。
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

    /// その行で「最も良い」列の位置。印を付けないときは空集合。
    ///
    /// - 向きの無い項目（平均・最大など）は常に空集合。
    /// - 値が 1 つしか無い行は空集合（比べる相手がいないのに印を付けても意味が無い）。
    /// - **全部同じ値なら空集合**（全部に印が付くと、印そのものが情報を持たなくなる）。
    /// - 同点で並んだ場合はその全部を返す（片方だけ選ぶ根拠が無い）。
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

    /// 行 → 印の付く列、をまとめて求める。
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
