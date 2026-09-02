import Foundation

/// `[Shot]` と BB 重量から計算される、純粋な値としてのセッション統計。
///
/// 保存も購読もせず、いつでも作り直せる派生値として扱う。UI 側は 1 発ごとに
/// `compute(shots:massGrams:)` を呼び直せばよい（O(n) で、実用上の発数では十分速い）。
public struct SessionStats: Sendable, Hashable, Codable {
    /// 発数。
    public let count: Int
    /// 計算に使った BB 重量（g）。
    public let massGrams: Double
    /// 平均初速（m/s）。0 発なら `nil`。
    public let meanMetersPerSecond: Double?
    /// 最大初速（m/s）。
    public let maxMetersPerSecond: Double?
    /// 最小初速（m/s）。
    public let minMetersPerSecond: Double?
    /// 標本標準偏差（n-1）。2 発未満では定義できないので `nil`。
    public let sampleStandardDeviation: Double?
    /// エクストリームスプレッド（max − min）。
    public let extremeSpread: Double?
    /// 1 発ごとのジュールの平均。
    public let meanJoules: Double?
    /// 最大初速でのジュール。
    public let maxJoules: Double?
    /// 本体が報告した連射速度の平均（発/秒）。報告のあるショットが 1 発も無ければ `nil`。
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

    /// 発数 0 の統計。
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

    /// ショット列から統計を計算する。
    ///
    /// - Parameters:
    ///   - shots: 対象のショット（順序は問わない）
    ///   - massGrams: BB 重量（g）。ジュール計算に使う。
    public static func compute(shots: [Shot], massGrams: Double) -> SessionStats {
        guard !shots.isEmpty else { return .empty(massGrams: massGrams) }

        let velocities = shots.map(\.velocityMetersPerSecond)
        let n = Double(velocities.count)
        let sum = velocities.reduce(0, +)
        let mean = sum / n
        // 最大・最小は空でないことを確認済みなので強制アンラップせず nil 合体で潰す。
        let maxV = velocities.max() ?? mean
        let minV = velocities.min() ?? mean

        // 標本標準偏差（n-1）。射撃データでは母集団ではなく標本を扱うため n-1 を使う。
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
