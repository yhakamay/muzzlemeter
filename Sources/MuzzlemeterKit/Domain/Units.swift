import Foundation

/// The display unit for muzzle velocity. Internally always represented as m/s.
public enum SpeedUnit: String, CaseIterable, Codable, Sendable {
    case metersPerSecond
    case feetPerSecond

    /// 1 m = 3.280839895 ft (the reciprocal of the defined value 1 ft = 0.3048 m).
    public static let feetPerMeter: Double = 3.280839895

    public var symbol: String {
        switch self {
        case .metersPerSecond: "m/s"
        case .feetPerSecond: "fps"
        }
    }

    /// The number of decimal digits shown. 1 for m/s, 0 for fps (fps values are large, so
    /// decimals carry little meaning).
    public var fractionDigits: Int {
        switch self {
        case .metersPerSecond: 1
        case .feetPerSecond: 0
        }
    }

    /// Converts a value in m/s to this unit.
    public func value(fromMetersPerSecond metersPerSecond: Double) -> Double {
        switch self {
        case .metersPerSecond: metersPerSecond
        case .feetPerSecond: metersPerSecond * Self.feetPerMeter
        }
    }

    /// Converts a value in this unit back to m/s.
    public func metersPerSecond(from value: Double) -> Double {
        switch self {
        case .metersPerSecond: value
        case .feetPerSecond: value / Self.feetPerMeter
        }
    }

    /// Whether the display **truncates** rather than rounds.
    ///
    /// The AC6000's own LCD **truncates** m/s to 1 decimal digit (confirmed on real
    /// hardware: raw 325 / 278 / 375 -> LCD 3.2 / 2.7 / 3.7). If the display drifted from
    /// the device's when firing the same BB, it would leave the user wondering "which one
    /// is broken," so only the m/s display is matched to the device. **The internal value
    /// and the CSV export always stay full precision.**
    public var truncatesDisplay: Bool {
        switch self {
        case .metersPerSecond: true
        case .feetPerSecond: false   // The device has no fps mode; this uses normal rounding.
        }
    }

    /// Formats a value in m/s as a numeric string in this unit (no unit symbol).
    public func format(metersPerSecond: Double) -> String {
        let converted = value(fromMetersPerSecond: metersPerSecond)
        let shown = truncatesDisplay ? Self.truncate(converted, digits: fractionDigits) : converted
        return String(format: "%.\(fractionDigits)f", shown)
    }

    /// Truncates to the given number of digits.
    ///
    /// Adds a tiny epsilon before truncating so that binary floating-point error (e.g.
    /// `2.78` actually being `2.7799…`) doesn't drop a digit.
    static func truncate(_ value: Double, digits: Int) -> Double {
        let factor = pow(10.0, Double(digits))
        return ((value * factor) + 1e-9).rounded(.down) / factor
    }

    /// Formats with the unit symbol attached. e.g. `"91.2 m/s"` / `"299 fps"`
    public func formatted(metersPerSecond: Double) -> String {
        "\(format(metersPerSecond: metersPerSecond)) \(symbol)"
    }
}

/// The display unit for rate of fire. Internally always represented as RPS (rounds/sec).
public enum RateOfFireUnit: String, CaseIterable, Codable, Sendable {
    case rps
    case rpm

    public var symbol: String {
        switch self {
        case .rps: "rps"
        case .rpm: "rpm"
        }
    }

    public var fractionDigits: Int {
        switch self {
        case .rps: 1
        case .rpm: 0
        }
    }

    public func value(fromRPS rps: Double) -> Double {
        switch self {
        case .rps: rps
        case .rpm: rps * 60.0
        }
    }

    public func rps(from value: Double) -> Double {
        switch self {
        case .rps: value
        case .rpm: value / 60.0
        }
    }

    public func format(rps: Double) -> String {
        String(format: "%.\(fractionDigits)f", value(fromRPS: rps))
    }

    public func formatted(rps: Double) -> String {
        "\(format(rps: rps)) \(symbol)"
    }
}
