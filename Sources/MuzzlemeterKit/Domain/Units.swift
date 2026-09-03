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

    /// 表示時に四捨五入ではなく**切り捨て**るか。
    ///
    /// AC6000 本体の LCD は m/s を**切り捨てて**小数 1 桁で出す（実機で確認:
    /// raw 325 / 278 / 375 → LCD 3.2 / 2.7 / 3.7）。同じ弾を撃って
    /// 本体とアプリで表示がずれると「どちらが壊れているのか」で悩ませてしまうため、
    /// m/s の表示だけは本体に合わせる。**内部値と CSV は常にフル精度のまま。**
    public var truncatesDisplay: Bool {
        switch self {
        case .metersPerSecond: true
        case .feetPerSecond: false   // 本体は fps を持たない。ここは通常の四捨五入。
        }
    }

    /// m/s の値を、この単位の数値文字列に整形する（単位記号なし）。
    public func format(metersPerSecond: Double) -> String {
        let converted = value(fromMetersPerSecond: metersPerSecond)
        let shown = truncatesDisplay ? Self.truncate(converted, digits: fractionDigits) : converted
        return String(format: "%.\(fractionDigits)f", shown)
    }

    /// 指定桁で切り捨てる。
    ///
    /// `2.78` が二進浮動小数で `2.7799…` になるような誤差で 1 桁落ちないよう、
    /// ごく小さい値を足してから切り捨てる。
    static func truncate(_ value: Double, digits: Int) -> Double {
        let factor = pow(10.0, Double(digits))
        return ((value * factor) + 1e-9).rounded(.down) / factor
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
