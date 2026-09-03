import Foundation

/// A single shot's measurement result.
///
/// Velocity is always held in **m/s**; conversion to the display unit (m/s / fps) is
/// done by `SpeedUnit`. The rate of fire is held exactly as **the value the device
/// sends** (`rawRev` from `docs/PROTOCOL.md` §7). When the device doesn't send a value
/// it's `nil`, in which case `RateOfFire` falls back to estimating it from the
/// difference between timestamps.
public struct Shot: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// Muzzle velocity (m/s).
    public let velocityMetersPerSecond: Double
    /// The rate of fire reported by the device (rounds/sec). `nil` if not reported.
    ///
    /// The AC6000's `FIRE_REPORT` (`0x52`) sends `rawRev`, but **whether its unit is
    /// RPS, RPM, or ×10 is unverified** (`docs/PROTOCOL.md` §7.1 / §10-2). Because of
    /// that, `MuzzlemeterDecoder` leaves this unfilled and puts the raw value into
    /// `rawRateOfFire` instead. The rate of fire shown in the UI is estimated by
    /// `RateOfFire.estimateRPS` from the difference between timestamps.
    public let rateOfFireRPS: Double?
    /// The **raw** rate-of-fire value reported by the device (`FIRE_REPORT`'s `rawRev`).
    /// A single shot reports 0. Kept as-is, unconverted, until the unit is confirmed.
    public let rawRateOfFire: UInt16?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        velocityMetersPerSecond: Double,
        rateOfFireRPS: Double? = nil,
        rawRateOfFire: UInt16? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.rateOfFireRPS = rateOfFireRPS
        self.rawRateOfFire = rawRateOfFire
    }

    /// Computes this shot's kinetic energy (J) from the BB weight.
    public func joules(massGrams: Double) -> Double {
        Energy.joules(massGrams: massGrams, velocityMetersPerSecond: velocityMetersPerSecond)
    }
}
