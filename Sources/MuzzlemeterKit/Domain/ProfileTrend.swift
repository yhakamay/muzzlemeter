import Foundation

/// 推移を出すための 1 セッション分の入力。**統計は呼び出し側で計算して渡す**。
///
/// セッションごとの統計はセッション詳細でも比較画面でも使う。ここで `[Shot]` から
/// 計算し直すと、同じ計算を画面ごとに繰り返すことになる。
public struct ProfileTrendSample: Sendable, Hashable {
    /// 呼び出し側がセッションに戻れるようにする不透明な識別子。
    public let id: String
    public let date: Date
    public let massGrams: Double
    /// 実効気温（手動 ?? 自動）。記録が無ければ `nil`。
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

/// チャートに打つ 1 点（＝ 1 セッション）。
public struct ProfileTrendPoint: Sendable, Hashable, Identifiable {
    public let id: String
    public let date: Date
    public let massGrams: Double
    public let temperatureC: Double?
    public let count: Int
    public let meanMetersPerSecond: Double
    /// 標本 SD。1 発しか無いセッションでは `nil`（エラーバーを描かない）。
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

    /// エラーバーの下端（平均 − SD）。SD が無ければ平均そのもの。
    public var lowerMetersPerSecond: Double {
        meanMetersPerSecond - (sampleStandardDeviation ?? 0)
    }

    /// エラーバーの上端（平均 + SD）。
    public var upperMetersPerSecond: Double {
        meanMetersPerSecond + (sampleStandardDeviation ?? 0)
    }
}

/// プロファイル全体のまとめ。
public struct ProfileTrendSummary: Sendable, Hashable {
    /// セッション数（**1 発も無い回も数える**。撃った回数の記録だから）。
    public let sessionCount: Int
    /// 合計発数。
    public let shotCount: Int
    /// 最後に撃った日。1 件も無ければ `nil`。
    public let lastSessionDate: Date?
    /// 全ショットを 1 つの標本として見たときの平均（m/s）。
    public let meanMetersPerSecond: Double?
    /// 全ショットを 1 つの標本として見たときの標本 SD（n−1）。
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

/// プロファイルの推移（平均弾速の時系列と、気温との関係）を組み立てる純粋なロジック。
public enum ProfileTrend {
    /// 散布図に意味を持たせるのに要る最低限の点数。
    ///
    /// 2 点は必ず直線で結べてしまい、「気温が上がると速くなる」と読めてしまう。
    /// 3 点未満のときは断りを添える。
    public static let minimumTemperaturePoints = 3

    /// 時系列の点。**1 発も無いセッションは落とす**（平均が無い点は打てない）。
    /// 並びは古い順（チャートの横軸と同じ向き）。
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

    /// 気温が記録されている点だけ。
    public static func temperaturePoints(_ points: [ProfileTrendPoint]) -> [ProfileTrendPoint] {
        points.filter { $0.temperatureC != nil }
    }

    /// BB 重量が回によって違うか。違うなら色で見分ける意味がある。
    public static func massGramsVaries(_ points: [ProfileTrendPoint]) -> Bool {
        guard let first = points.first else { return false }
        // 0.001 g 未満の差は表示（小数 2 桁）で区別できないので同じ扱い。
        return points.contains { abs($0.massGrams - first.massGrams) > 0.001 }
    }

    /// 出てくる BB 重量（軽い順）。凡例の並びに使う。
    public static func massGramsValues(_ points: [ProfileTrendPoint]) -> [Double] {
        var seen: [Double] = []
        for point in points where !seen.contains(where: { abs($0 - point.massGrams) <= 0.001 }) {
            seen.append(point.massGrams)
        }
        return seen.sorted()
    }

    /// 全体のまとめ。
    ///
    /// 平均は発数で重み付けした平均、SD は**全ショットを 1 つの標本と見たときの
    /// 標本 SD**。セッションごとの SD を平均してはいけない（セッション間の
    /// ばらつきが抜け落ちる）。次の分解式をそのまま使う:
    ///
    ///     (N−1)·s² = Σ (nᵢ−1)·sᵢ² + Σ nᵢ·(mᵢ − M)²
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

    /// 指定した日時にいちばん近い点。チャートをタップしたときの当たり判定に使う。
    public static func nearestPoint(to date: Date, in points: [ProfileTrendPoint]) -> ProfileTrendPoint? {
        points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
}
