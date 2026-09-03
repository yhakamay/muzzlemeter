import Foundation

/// 本体内ログ 1 件。
///
/// **実機確定の形式**（`docs/PROTOCOL.md` §6.6）だが、生 payload も必ず持ち歩く。
/// `shot` が `nil` のレコードは応答が解釈できなかったことを意味し、上位はそこで
/// 読み出しを止めて生データを保存する（未知のファームウェア差異への保険）。
public struct DeviceLogRecord: Sendable, Hashable {
    /// 応答が載せていた index（1 始まり）。
    public let index: Int
    /// `0x63` フレームの payload（cmd の次から checksum の手前まで）。
    public let payload: [UInt8]
    /// 読めた 1 発（速度が乗っていたレコード）。**実機確定**。
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
    /// 要求した範囲を最後まで読めた（0 件だった場合、および全ゼロレコードで
    /// ログの終端に達した場合を含む。§6.6 の「全ゼロ＝終端」はエラーではない）。
    case completed
    /// このレコードが `0x63` の応答として読めなかったので**そこで止めた**。
    /// 生データを保存してユーザーに送り返してもらう。実機確定後は通常起きないはずだが、
    /// 未知のファームウェア差異に対する保険として残してある。
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

    /// 実際に読めた末尾の index。ボラタイルなログを差分で読むとき、
    /// 「どこまで取り込んだか」の印を進めるのに使う（`nil` なら 1 件も読めなかった）。
    public var lastReadIndex: Int? { records.last?.index }
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
    /// 読み出しを始める 1 始まりの index。
    ///
    /// 本体内ログは **volatile**（電源を切ると 0 件に戻る）。同じ電源サイクルの間に
    /// 既に取り込んだぶんを読み直さないよう、呼び出し側（`ChronoService`）が
    /// 「前回どこまで読んだか」を覚えておいて、その続きから渡す。既定は 1（先頭から全部）。
    public var startIndex: Int

    public init(
        responseTimeout: TimeInterval = 3.0,
        commandGap: TimeInterval = 0.3,
        maximumRecords: Int = 200,
        startIndex: Int = 1
    ) {
        self.responseTimeout = responseTimeout
        self.commandGap = commandGap
        self.maximumRecords = maximumRecords
        self.startIndex = max(1, startIndex)
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
