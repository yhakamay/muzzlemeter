import Foundation

/// 連射速度（ROF）のフォールバック推定。
///
/// AC6000 は FIRE_REPORT に `rawRev`（連射速度の生値）を含めて送ってくるため、
/// 通常は `Shot.rateOfFireRPS` をそのまま使う。ここにあるのは
/// **本体が ROF を報告しない場合／報告値がまだデコードできない場合**のための
/// タイムスタンプ差からの推定で、ショット時刻の差分だけを使う純粋関数。
public enum RateOfFire {
    /// この秒数より大きい間隔が空いたらバーストが切れたとみなす。
    public static let defaultBurstGapThreshold: TimeInterval = 1.0

    /// 直近のバーストの発射速度（発/秒）を推定する。
    ///
    /// 最後のショットから時間を遡り、直前のショットとの間隔が `burstGapThreshold`
    /// 以下である限り同じバーストとみなす。バーストが 1 発しかない（＝単発）場合は
    /// 速度を定義できないので `nil` を返す。
    ///
    /// - Parameters:
    ///   - shots: ショット列。順序は問わない（内部で時刻順にソートする）。
    ///   - burstGapThreshold: バーストの切れ目とみなす間隔（秒）。
    public static func estimateRPS(
        shots: [Shot],
        burstGapThreshold: TimeInterval = defaultBurstGapThreshold
    ) -> Double? {
        estimateRPS(timestamps: shots.map(\.timestamp), burstGapThreshold: burstGapThreshold)
    }

    /// タイムスタンプ列から直近バーストの発射速度（発/秒）を推定する。
    public static func estimateRPS(
        timestamps: [Date],
        burstGapThreshold: TimeInterval = defaultBurstGapThreshold
    ) -> Double? {
        let burst = latestBurst(timestamps: timestamps, burstGapThreshold: burstGapThreshold)
        guard burst.count >= 2, let first = burst.first, let last = burst.last else { return nil }
        let duration = last.timeIntervalSince(first)
        guard duration > 0 else { return nil }
        // n 発の間には n-1 個の間隔がある。
        return Double(burst.count - 1) / duration
    }

    /// 直近のバーストに属するタイムスタンプを時刻昇順で返す。
    ///
    /// 単発だった場合は要素 1 個の配列（空入力なら空配列）を返す。
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
