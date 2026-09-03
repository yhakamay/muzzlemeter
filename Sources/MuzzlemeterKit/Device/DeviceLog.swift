import Foundation

/// 本体内ログ 1 件。
///
/// **形式が未検証なので、生 payload を必ず持ち歩く。** `shot` が `nil` のレコードは
/// 「読めなかった」を意味し、上位はそこで読み出しを止めて生データを保存する。
public struct DeviceLogRecord: Sendable, Hashable {
    /// 要求した番号（0 始まり）。応答に index が載っているかは未確定なので、
    /// **要求した側が付けた番号**である（`ChronoEvent.logRecordRaw` の doc 参照）。
    public let index: Int
    /// `0x63` フレームの payload（cmd の次から checksum の手前まで）。
    public let payload: [UInt8]
    /// `FIRE_REPORT` と同じ並びに見えたときだけ入る 1 発（**推定**）。
    public let shot: Shot?

    public init(index: Int, payload: [UInt8], shot: Shot?) {
        self.index = index
        self.payload = payload
        self.shot = shot
    }

    public var isParsed: Bool { shot != nil }

    /// デバッグ用の 1 行。`<index> <payload hex>`。
    ///
    /// ユーザーがそのまま貼って送り返せる形にしておく。**これが唯一の
    /// 「実物の 0x63 応答」を手に入れる経路**なので、解釈に失敗しても必ず残す。
    public var hexLine: String {
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "\(index) \(hex)"
    }
}

/// 読み出しがどこで終わったか。
public enum DeviceLogOutcome: Sendable, Hashable {
    /// 件数ぶん全部読めた（0 件だった場合も含む）。
    case completed
    /// このレコードが `FIRE_REPORT` の並びとして読めなかったので**そこで止めた**。
    /// 生データを保存してユーザーに送り返してもらう。
    case unsupportedFormat(index: Int)
    /// 応答が来なかった。`index` が `nil` なら件数（`0x62`）の段階で来なかった。
    case timedOut(index: Int?)
    /// 読み出しを始められなかった（未接続 / 書き込み先が無い / 既に読み出し中）。
    case unavailable(String)
}

/// 本体内ログの読み出し結果。
public struct DeviceLogReadResult: Sendable, Hashable {
    /// `0x62` が答えた件数。読めなかったときは 0。
    public let reportedCount: Int
    /// 受け取れたレコード（先頭から順。読めなかった 1 件も末尾に含む）。
    public let records: [DeviceLogRecord]
    public let outcome: DeviceLogOutcome

    public init(reportedCount: Int, records: [DeviceLogRecord], outcome: DeviceLogOutcome) {
        self.reportedCount = reportedCount
        self.records = records
        self.outcome = outcome
    }

    /// 1 発として読めたぶん。**セッションに保存してよいのはこれだけ。**
    public var shots: [Shot] { records.compactMap(\.shot) }

    public var isComplete: Bool { outcome == .completed }

    /// 何も受け取れなかったか（保存するものが無い）。
    public var isEmpty: Bool { shots.isEmpty }
}

/// 本体内ログ読み出しの詰め方。
///
/// 実測の初期化シーケンス（`docs/PROTOCOL.md` §4.2）に合わせて
/// **1 本ずつ・応答を待って ~300 ms 間隔**で送る。まとめて投げない。
public struct DeviceLogReadOptions: Sendable, Hashable {
    /// 1 件あたりの応答待ち。実測の応答は 45–63 ms なので 3 秒あれば十分。
    public var responseTimeout: TimeInterval
    /// 次のコマンドまでの間隔。
    public var commandGap: TimeInterval
    /// 安全弁。本体が壊れた件数を返しても、この数で打ち切る。
    public var maximumRecords: Int

    public init(
        responseTimeout: TimeInterval = 3.0,
        commandGap: TimeInterval = 0.3,
        maximumRecords: Int = 200
    ) {
        self.responseTimeout = responseTimeout
        self.commandGap = commandGap
        self.maximumRecords = maximumRecords
    }
}

/// 読み出しの進み具合（`done / total`）。
public struct DeviceLogProgress: Sendable, Hashable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}
