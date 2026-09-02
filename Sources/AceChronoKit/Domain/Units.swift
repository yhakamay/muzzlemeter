import Foundation

/// 弾速の表示単位。内部表現は常に m/s。
public enum SpeedUnit: String, CaseIterable, Codable, Sendable {
    case metersPerSecond
    case feetPerSecond

    /// 1 m = 3.280839895 ft（定義値 1 ft = 0.3048 m の逆数）。
    public static let feetPerMeter: Double = 3.280839895

    public var symbol: String {
        switch self {
        case .metersPerSecond: "m/s"
        case .feetPerSecond: "fps"
        }
    }

    /// 表示時の小数桁数。m/s は 1 桁、fps は 0 桁（fps は値が大きく小数に意味が薄いため）。
    public var fractionDigits: Int {
        switch self {
        case .metersPerSecond: 1
        case .feetPerSecond: 0
        }
    }

    /// m/s の値をこの単位へ換算する。
    public func value(fromMetersPerSecond metersPerSecond: Double) -> Double {
        switch self {
        case .metersPerSecond: metersPerSecond
        case .feetPerSecond: metersPerSecond * Self.feetPerMeter
        }
    }

    /// この単位の値を m/s へ換算する。
    public func metersPerSecond(from value: Double) -> Double {
        switch self {
        case .metersPerSecond: value
        case .feetPerSecond: value / Self.feetPerMeter
        }
    }

    /// m/s の値を、この単位の数値文字列に整形する（単位記号なし）。
    public func format(metersPerSecond: Double) -> String {
        String(format: "%.\(fractionDigits)f", value(fromMetersPerSecond: metersPerSecond))
    }

    /// 単位記号付きで整形する。例: `"91.2 m/s"` / `"299 fps"`
    public func formatted(metersPerSecond: Double) -> String {
        "\(format(metersPerSecond: metersPerSecond)) \(symbol)"
    }
}

/// 連射速度の表示単位。内部表現は常に RPS（発/秒）。
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
