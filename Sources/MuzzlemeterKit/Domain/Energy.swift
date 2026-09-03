import Foundation

/// BB 弾の運動エネルギー計算。
public enum Energy {
    /// 運動エネルギー E = 1/2 * m * v^2 （m は kg、v は m/s、戻り値は J）。
    /// - Parameters:
    ///   - massGrams: BB 弾重量（グラム）。例: 0.20, 0.25, 0.28
    ///   - velocityMetersPerSecond: 初速（m/s）
    /// - Returns: ジュール
    public static func joules(massGrams: Double, velocityMetersPerSecond: Double) -> Double {
        0.5 * (massGrams / 1000.0) * velocityMetersPerSecond * velocityMetersPerSecond
    }
}
