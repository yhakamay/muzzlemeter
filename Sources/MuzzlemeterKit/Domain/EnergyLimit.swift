import Foundation

/// 規制上限に対する 1 発の立ち位置。
///
/// エアソフトで一番怖いのは「気づかないうちに上限を越えていた」状態なので、
/// **越えたかどうか**だけでなく「あと少しで越える」を独立した段階として持つ。
/// 越えてからでは遅く、ホップやスプリングを調整する猶予が要るため。
public enum EnergyMargin: String, Sendable, Hashable, Codable, CaseIterable {
    /// 上限より十分下（既定では上限の 90 % 以下）。
    case safe
    /// 上限に近い（上限の 90 % 超〜上限未満）。
    case caution
    /// 上限ちょうど、またはそれ以上。
    case over

    public var isOver: Bool { self == .over }
    /// 注意喚起（色・音・ハプティクス）を出すべきか。
    public var needsAttention: Bool { self != .safe }
}

/// 規制上限（プロファイルごとの J）に対する判定。
///
/// アプリ側ではなくキットに置いてあるのは、**しきい値の決め方そのものが仕様**であり、
/// UI に埋めるとテストできなくなるため。境界の扱い（上限ちょうどは「超過」）も
/// ここ 1 箇所で決める。
public enum EnergyLimit {
    /// 「注意」に入る幅。上限の 10 % 以内に入ったら注意。
    public static let defaultCautionFraction: Double = 0.10

    /// 1 発のジュールを上限と比べて段階に落とす。
    ///
    /// - Parameters:
    ///   - joules: 判定するエネルギー（J）
    ///   - limitJoules: 規制上限（J）。0 以下なら上限なしとして常に `.safe`。
    ///   - cautionFraction: 「注意」に入る幅（上限に対する比）。
    /// - Returns: `joules >= limit` なら `.over`、`limit * (1 - fraction) < joules < limit` なら
    ///   `.caution`、それ以外は `.safe`。
    ///
    /// **上限ちょうどは `.over`。** 法令上限 0.98 J は「0.98 J を超えてはならない」ではなく
    /// 運用上「0.98 J 未満で収める」ものとして扱われるので、ちょうどを安全側に倒す。
    public static func margin(
        joules: Double,
        limitJoules: Double,
        cautionFraction: Double = defaultCautionFraction
    ) -> EnergyMargin {
        guard limitJoules > 0, joules.isFinite else { return .safe }
        if joules >= limitJoules { return .over }
        let cautionThreshold = limitJoules * (1.0 - max(0, min(1, cautionFraction)))
        return joules > cautionThreshold ? .caution : .safe
    }

    /// 速度（m/s）と BB 重量から直接判定する版。
    public static func margin(
        massGrams: Double,
        velocityMetersPerSecond: Double,
        limitJoules: Double,
        cautionFraction: Double = defaultCautionFraction
    ) -> EnergyMargin {
        margin(
            joules: Energy.joules(
                massGrams: massGrams,
                velocityMetersPerSecond: velocityMetersPerSecond
            ),
            limitJoules: limitJoules,
            cautionFraction: cautionFraction
        )
    }

    /// 上限までの余裕（J）。越えていれば負の値（＝超過分）になる。
    public static func headroomJoules(joules: Double, limitJoules: Double) -> Double {
        limitJoules - joules
    }

    /// 上限を越えたショットの数。セッションのまとめに出す。
    public static func overLimitCount(
        shots: [Shot],
        massGrams: Double,
        limitJoules: Double
    ) -> Int {
        shots.reduce(into: 0) { count, shot in
            if margin(
                joules: shot.joules(massGrams: massGrams),
                limitJoules: limitJoules
            ).isOver {
                count += 1
            }
        }
    }

    /// 上限を越えない最大初速（m/s）。BB 重量が 0 以下なら `nil`。
    ///
    /// 「あと何 m/s 出せるか」を出すために使う。E = ½mv² を v について解いただけ。
    public static func maxVelocity(massGrams: Double, limitJoules: Double) -> Double? {
        guard massGrams > 0, limitJoules > 0 else { return nil }
        return (2.0 * limitJoules / (massGrams / 1000.0)).squareRoot()
    }
}
