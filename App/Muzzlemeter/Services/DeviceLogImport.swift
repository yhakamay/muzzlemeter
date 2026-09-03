import MuzzlemeterKit
import Foundation
import SwiftData

/// 本体内ログの取り込みが今どうなっているか。
///
/// **作業を止めない**ため、取り込みは接続ピルの下の帯だけで完結させる（画面遷移も
/// モーダルも無い）。帯の見た目はこの 3 状態だけで決まる。
enum DeviceLogImportState: Equatable {
    /// 何もしていない（未取込があれば「取り込みますか」の帯が出る）。
    case idle
    /// 読み出し中。`done / total` をそのまま帯に出す。
    case importing(done: Int, total: Int)
    /// 終わった。結果を出して、閉じるまで残す。
    case finished(DeviceLogImportSummary)
}

/// 取り込みの結果。
struct DeviceLogImportSummary: Equatable {
    enum Outcome: Equatable {
        /// 件数ぶん全部読めた。
        case completed
        /// 途中で**未対応の形式**が出たので止めた（`docs/PROTOCOL.md` §6.6）。
        case unsupportedFormat
        /// 本体が応答しなかった（要求の形自体が違う可能性がある）。
        case noResponse
    }

    /// セッションとして保存できた発数。
    let savedShotCount: Int
    let outcome: Outcome
    /// 生データを書き出したファイル名（Documents 直下）。書き出していなければ nil。
    let debugFileName: String?

    var isSuccess: Bool { outcome == .completed }
}

/// 読めなかった `0x63` の生 payload をファイルに残す。
///
/// 実機確定の形式（`docs/PROTOCOL.md` §6.6）だが、未知のファームウェア差異への保険として
/// 残してある。形式が違ったときにその場で捨ててしまうと、ユーザーの手元にある実機の
/// 応答が永久に分からない。ファイル App から共有できる Documents 直下に置き、送り返してもらう。
enum DeviceLogArchive {
    /// `device-log-<yyyyMMdd-HHmmss>.txt` を書き出してファイル名を返す。失敗したら nil。
    static func write(records: [DeviceLogRecord], now: Date = Date()) -> String? {
        guard !records.isEmpty else { return nil }
        guard let directory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "device-log-\(formatter.string(from: now)).txt"

        // 文言は**翻訳しない**。読むのは開発者で、そのまま貼って共有されるファイル。
        var lines = [
            "# Muzzlemeter device log dump",
            "# AC6000 MKIII BT / 0x63 response payload (format confirmed, docs/PROTOCOL.md 6.6)",
            "# one record per line: <index> <payload hex>",
        ]
        lines.append(contentsOf: records.map(\.hexLine))
        let text = lines.joined(separator: "\n") + "\n"

        do {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return name
        } catch {
            return nil
        }
    }
}

/// 取り込んだショットを 1 件のセッションにする。
///
/// **進行中のセッションには一切触らない。** 取り込みは過去の記録であって、
/// いま撃っている最中の計測とは別物。混ぜると「そのセッションで何発撃ったか」が壊れる。
enum DeviceLogSessionBuilder {
    /// 取り込みで付けるタグ。後から履歴で絞り込めるように固定の 1 語にする。
    static var tag: String { String(localized: "本体ログ") }

    @MainActor
    static func insertSession(
        shots: [Shot],
        variables: SessionVariables,
        profile: GunProfile?,
        gunName: String,
        isPartial: Bool,
        into modelContext: ModelContext
    ) -> Session? {
        guard !shots.isEmpty else { return nil }
        let session = Session(
            startedAt: shots.first?.timestamp ?? Date(),
            endedAt: shots.last?.timestamp ?? Date(),
            title: String(localized: "本体ログ \(shots.count) 件"),
            gunName: gunName,
            variables: variables,
            gunPowerCategory: profile?.powerCategory,
            energyLimitJoules: profile?.energyLimitJoules ?? 0.98,
            gunManufacturer: profile?.manufacturer ?? "",
            gunModel: profile?.model ?? "",
            gunInnerBarrelLengthMm: profile?.innerBarrelLengthMm
        )
        session.tags = [tag]
        // **出どころと、時刻が無いことを記録に残す。** 本体（クロノグラフ）内蔵のログから
        // 取り込んでおり、そのログには計測時刻が入っていないので、並んでいる時刻は
        // 「取り込んだ時刻」でしかない。書いておかないと、後から見た人が
        // 「この日のこの時間に撃った」と誤読する。
        var notes = [
            String(localized: "本体（クロノグラフ）内蔵のログから取り込みました。本体はログに計測時刻を記録しないため、取り込んだ時刻を表示しています。")
        ]
        if isPartial {
            notes.append(String(localized: "未対応の形式が出たところで読み出しを止めました。ここまでが読めたぶんです。"))
        }
        // 環境（気温など）も取らない。撃った場所でも時刻でもないので、
        // いまの天気を入れると嘘になる。
        session.manualNotes = notes.joined(separator: "\n")
        modelContext.insert(session)
        for shot in shots {
            let record = ShotRecord(shot: shot, session: session)
            modelContext.insert(record)
            session.shots.append(record)
        }
        return session
    }
}
