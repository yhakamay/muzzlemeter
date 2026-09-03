import Foundation

/// Where a single shot stands relative to the regulation limit.
///
/// The scariest thing in airsoft is "the limit was exceeded without anyone noticing," so
/// this holds not just **whether it was exceeded** but "about to be exceeded" as its own
/// independent stage. Waiting until it's already exceeded is too late — there needs to be
/// room to adjust the hop or spring beforehand.
public enum EnergyMargin: String, Sendable, Hashable, Codable, CaseIterable {
    /// Comfortably under the limit (by default, 90% of the limit or less).
    case safe
    /// Close to the limit (over 90% of the limit, but under it).
    case caution
    /// Exactly at the limit, or over it.
    case over

    public var isOver: Bool { self == .over }
    /// Whether an alert (color / sound / haptics) should be raised.
    public var needsAttention: Bool { self != .safe }
}

/// Judgment against the regulation limit (in J, per profile).
///
/// This lives in the kit rather than the app because **how the threshold is decided is
/// itself part of the spec**, and burying it in the UI would make it untestable. How the
/// boundary is handled (exactly at the limit counts as "exceeded") is also decided in
/// this one place.
public enum EnergyLimit {
    /// The width of the "caution" band. Within 10% of the limit triggers caution.
    public static let defaultCautionFraction: Double = 0.10

    /// Reduces one shot's joules, compared against the limit, to a stage.
    ///
    /// - Parameters:
    ///   - joules: the energy being judged (J)
    ///   - limitJoules: the regulation limit (J). `<= 0` means no limit, always `.safe`.
    ///   - cautionFraction: the width of the "caution" band, as a fraction of the limit.
    /// - Returns: `.over` if `joules >= limit`, `.caution` if
    ///   `limit * (1 - fraction) < joules < limit`, otherwise `.safe`.
    ///
    /// **Exactly at the limit is `.over`.** A legal limit of 0.98 J is treated in practice
    /// not as "must not exceed 0.98 J" but as "must stay under 0.98 J," so the exact
    /// boundary is resolved on the safe side.
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

    /// A variant that judges directly from velocity (m/s) and BB weight.
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

    /// Headroom under the limit (J). Negative (i.e. the overage) once exceeded.
    public static func headroomJoules(joules: Double, limitJoules: Double) -> Double {
        limitJoules - joules
    }

    /// The number of shots that exceeded the limit. Shown in the session summary.
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

    /// The maximum velocity (m/s) that stays under the limit. `nil` if the BB weight is
    /// `<= 0`.
    ///
    /// Used to show "how much more speed is available." Just E = ½mv² solved for v.
    public static func maxVelocity(massGrams: Double, limitJoules: Double) -> Double? {
        guard massGrams > 0, limitJoules > 0 else { return nil }
        return (2.0 * limitJoules / (massGrams / 1000.0)).squareRoot()
    }
}
