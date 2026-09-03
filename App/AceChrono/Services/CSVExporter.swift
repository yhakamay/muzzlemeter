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
        "power_source",
        "manufacturer",
        "model",
        "inner_barrel_mm",
        "bb_weight_g",
        "velocity_mps",
        "velocity_fps",
        "joules",
        "interval_ms",
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
        // パワーソースは表示名ではなく raw 値を出す。表計算で集計するときに
        // 言語設定で列の中身が変わってしまうと使い物にならない。
        let powerSource = session.gunPowerSourceRaw
        let manufacturer = escape(session.gunManufacturer)
        let model = escape(session.gunModel)
        let barrel = session.gunInnerBarrelLengthMm.map(String.init) ?? ""
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
                powerSource,
                manufacturer,
                model,
                barrel,
                String(format: "%.2f", session.bbWeightGrams),
                String(format: "%.2f", mps),
                String(format: "%.1f", SpeedUnit.feetPerSecond.value(fromMetersPerSecond: mps)),
                String(format: "%.3f", shot.joules(massGrams: session.bbWeightGrams)),
                interval.map { String(format: "%.0f", $0) } ?? "",
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
