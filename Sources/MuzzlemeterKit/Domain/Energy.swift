import Foundation

/// Kinetic energy calculation for a BB.
public enum Energy {
    /// Kinetic energy E = 1/2 * m * v^2 (m in kg, v in m/s, returns J).
    /// - Parameters:
    ///   - massGrams: BB weight in grams. e.g. 0.20, 0.25, 0.28
    ///   - velocityMetersPerSecond: muzzle velocity (m/s)
    /// - Returns: joules
    public static func joules(massGrams: Double, velocityMetersPerSecond: Double) -> Double {
        0.5 * (massGrams / 1000.0) * velocityMetersPerSecond * velocityMetersPerSecond
    }
}
