import AceChronoKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// セッションを CSV に書き出す。
///
/// 列は表計算にそのまま貼れる並びにしてある。速度は m/s と fps の**両方**を出す
/// （表示単位の設定に関係なく、後から見て困らないようにするため）。
enum CSVExporter {
    static let header = [
        "timestamp",
        "session_id",
        "session_title",
        "gun",
        "power_category",
        "manufacturer",
        "model",
        "inner_barrel_mm",
        "bb_weight_g",
        "gas_type",
        "hop_setting",
        "energy_limit_j",
        "velocity_mps",
        "velocity_fps",
        "joules",
        "interval_ms",
        "temperature_c",
        "humidity_pct",
        "pressure_hpa",
        "weather",
        "place",
        "env_notes",
    ]
    .joined(separator: ",")

    static func csv(for sessions: [Session]) -> String {
        var lines = [header]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            lines.append(contentsOf: rows(for: session))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csv(for session: Session) -> String {
        ([header] + rows(for: session)).joined(separator: "\n") + "\n"
    }

    private static func rows(for session: Session) -> [String] {
        let sessionID = Self.identifier(for: session)
        let gun = escape(session.gunName)
        let title = escape(session.displayTitle)
        // 区分とガス種別は表示名ではなく raw 値を出す。表計算で集計するときに
        // 言語設定で列の中身が変わってしまうと使い物にならない。
        let powerCategory = session.gunPowerCategoryRaw
        // ガス種別は区分がガスのときだけ意味を持つ。それ以外は空欄にする
        // （電動の行に「hfc134a」が並ぶと、集計の邪魔にしかならない）。
        let gasType = session.gasType?.rawValue ?? ""
        let hopSetting = escape(session.hopSetting)
        let energyLimit = String(format: "%.2f", session.energyLimitJoules)
        let manufacturer = escape(session.gunManufacturer)
        let model = escape(session.gunModel)
        let barrel = session.gunInnerBarrelLengthMm.map(String.init) ?? ""
        // 環境は**実効値**（手動 ?? 自動）を出す。CSV を読む側は「どちらが入っているか」
        // ではなく「そのとき何度だったか」を知りたい。湿度だけは 0–1 ではなく % にする。
        let temperature = session.temperatureC.map { String(format: "%.1f", $0) } ?? ""
        let humidity = session.humidity.map { String(format: "%.0f", $0 * 100) } ?? ""
        let pressure = session.pressureHPa.map { String(format: "%.0f", $0) } ?? ""
        let weather = escape(session.autoConditionText ?? "")
        let place = escape(session.placeName ?? "")
        let envNotes = escape(session.manualNotes ?? "")
        var previous: Date?
        return session.orderedShots.map { shot in
            let interval = previous.map { (shot.timestamp.timeIntervalSince($0) * 1000).rounded() }
            previous = shot.timestamp
            let mps = shot.velocityMetersPerSecond
            return [
                timestampStyle.format(shot.timestamp),
                sessionID,
                title,
                gun,
                powerCategory,
                manufacturer,
                model,
                barrel,
                String(format: "%.2f", session.bbWeightGrams),
                gasType,
                hopSetting,
                energyLimit,
                String(format: "%.2f", mps),
                String(format: "%.1f", SpeedUnit.feetPerSecond.value(fromMetersPerSecond: mps)),
                String(format: "%.3f", shot.joules(massGrams: session.bbWeightGrams)),
                interval.map { String(format: "%.0f", $0) } ?? "",
                temperature,
                humidity,
                pressure,
                weather,
                place,
                envNotes,
            ]
            .joined(separator: ",")
        }
    }

    /// セッションの安定した識別子。SwiftData の永続 ID は文字列表現が長いので、
    /// 開始時刻ベースの読みやすい ID にする。
    static func identifier(for session: Session) -> String {
        idFormatter.string(from: session.startedAt)
    }

    static func fileName(for session: Session) -> String {
        "acechrono-\(identifier(for: session)).csv"
    }

    static var allSessionsFileName: String {
        "acechrono-\(idFormatter.string(from: Date())).csv"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// ISO8601（ミリ秒付き・ローカルタイムゾーン）。`ISO8601DateFormatter` は Sendable では
    /// ないので、値型の FormatStyle を使う。
    private static let timestampStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .current
    )

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// `ShareLink` に渡すための CSV ファイル。
struct CSVFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { file in
            Data(file.text.utf8)
        }
        .suggestedFileName { $0.name }
    }
}
