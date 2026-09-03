import Foundation

/// 弾速計との接続状態。
///
/// 本体は接続直後に鍵ハンドシェイク（`docs/PROTOCOL.md` §4.3）を要求するため、
/// `pairing` はその段階を表現するために用意してある。
/// 実際の遷移はハンドシェイクを実装した時点で使い始める。
public enum ConnectionState: Sendable, Equatable {
    case idle
    case scanning
    case connecting
    case pairing
    case ready
    case disconnected(reason: String?)

    public var isReady: Bool { self == .ready }

    /// 何らかの接続動作中（＝ユーザーに「接続中…」と見せてよい状態）。
    public var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .pairing: true
        case .idle, .ready, .disconnected: false
        }
    }
}

/// 本体が持つ「弾」の設定 1 件。
///
/// `0x5A`（現在選択中の弾）と `0x47`（プリセットスロット）の両方がこの 4 バイトを載せる
/// （`docs/PROTOCOL.md` §6.4）。
///
/// **スケールは推定のまま**なので、`rawDiameter` / `rawWeight` を必ず併せて公開する:
/// * キャプチャのプリセットは `20 / 25 / 43 / 45 / 88` で、×100 と読むと実在する
///   6 mm BB 重量（0.20〜0.88 g）に完全一致した。
/// * しかし実機の自発通知では同じスロット 1 に `0x00c8 = 200` が現れた。×100 なら 2.00 g で
///   実在しない重量になる（×1000 なら 0.20 g）。**単位系が 2 種類ある可能性がある。**
///   このため UI は `weightGrams` を鵜呑みにせず、必要なら raw を見て判断すること。
public struct AmmoRecord: Sendable, Hashable, Codable {
    /// プリセット番号（1 始まり）。
    public let slot: Int
    /// 直径のワイヤ値。mm × 100 と推定（実測は全スロット 600 = 6.00 mm）。
    public let rawDiameter: UInt16
    /// 重量のワイヤ値。g × 100 と推定（上記の但し書きを参照）。
    public let rawWeight: UInt16
    /// `0x5A`（現在選択中）由来なら `true`、`0x47`（プリセット読み出し）なら `false`。
    public let isCurrent: Bool
    /// `0x47` の payload[1]。キャプチャでは 0x41、実機の自発通知では 0x40 だった。
    /// 「読み出し応答 / 自発通知」の区別と推定（**未検証**）。`0x5A` では payload[0]。
    public let marker: UInt8

    public init(
        slot: Int,
        rawDiameter: UInt16,
        rawWeight: UInt16,
        isCurrent: Bool,
        marker: UInt8
    ) {
        self.slot = slot
        self.rawDiameter = rawDiameter
        self.rawWeight = rawWeight
        self.isCurrent = isCurrent
        self.marker = marker
    }

    /// `0x47` の payload[1] が取る値のうち、**自発通知**と推定されるもの。
    /// 実機追試（`docs/PROTOCOL.md` §6.3）で観測。読み出し応答は `0x41`。
    public static let spontaneousMarker: UInt8 = 0x40

    /// 直径（mm）。スケールは**推定**（実測は全スロット 600 = 6.00 mm）。
    public var diameterMm: Double { Double(rawDiameter) / 100.0 }

    /// 重量（g）。**スケールが 1 つに決まっていないので寛容に読む。**
    ///
    /// キャプチャのプリセットは `20 / 25 / 43 / 45 / 88`（×100 で 0.20〜0.88 g）だったが、
    /// 実機の自発通知では同じスロット 1 に `200` が来た（×1000 で 0.20 g）。
    /// 6 mm BB の実在重量は 0.12〜1.0 g 程度で、
    ///
    /// * ×100 で意味を成す値は 12〜100 の範囲
    /// * ×1000 で意味を成す値は 120〜1000 の範囲
    ///
    /// と重ならない。そこで **100 以上なら ×1000、未満なら ×100** と読む。
    /// この境目（100 = 1.00 g か 0.10 g か）はどちらも実在しない重量なので、
    /// 誤読しても実害のある範囲に入らない。
    ///
    /// 0（未設定）と、読み替えても実在しない重量になる値は `nil` を返す。
    /// **判断が付かないときに黙って数字を出さない**のが要点で、この値は
    /// 「本体の設定と食い違っていませんか」という警告の根拠に使われる。
    public var weightGrams: Double? {
        guard rawWeight > 0 else { return nil }
        let grams = rawWeight >= 100
            ? Double(rawWeight) / 1000.0
            : Double(rawWeight) / 100.0
        guard grams >= 0.10, grams <= 2.0 else { return nil }
        return grams
    }
}

/// 弾速計から流れてくるアプリ向けのイベント。
///
/// `ChronoPacketDecoder` が生バイト列をこれに変換し、`ChronoDevice` が
/// `AsyncStream<ChronoEvent>` として配信する。
public enum ChronoEvent: Sendable, Equatable {
    case shot(Shot)
    case battery(percent: Int)
    case deviceInfo(model: String, firmware: String?)
    /// `0x41` ACK。`command` は応答対象の cmd（ハンドシェイクでは `0x4B`）。
    case ack(command: UInt8)
    /// `0x4E` NAK。未知コマンドへの拒否応答。**実機確定**（`docs/PROTOCOL.md` §6.7）。
    case nak
    /// 弾の設定（`0x5A` / `0x47`）。**要求していなくても本体から自発的に飛んでくる**。
    case ammo(AmmoRecord)
    /// 本体内のログ件数（`0x62`）。payload[0]（**実機確定**。`docs/PROTOCOL.md` §6.5）。
    /// このログは volatile（本体の電源を切ると 0 件に戻る）。
    case logCount(Int)
    /// 本体内ログ 1 件の**生ペイロード**（`0x63`。`[index, rev0, rev1, speed0, speed1]`）。
    ///
    /// 解釈できたかどうかに関わらず必ずこれを流す（未知ファームウェア差異への保険）。
    /// `index` は応答に載っている番号（1 始まり。**実機確定**）。
    case logRecordRaw(index: Int, payload: [UInt8])
    /// 上記のうち、速度が乗っていた（＝実弾）ものを 1 発として読んだもの。
    /// velocity = `speed` raw ÷ 100 m/s、`shot.rawRateOfFire` = `rev` raw（意味は未確定）。
    /// **実機確定**（`docs/PROTOCOL.md` §6.6）。
    case logRecord(index: Int, shot: Shot)
    /// 全ゼロの `0x63` 応答。件数を超える index、または電源投入後まだ記録が無い index に
    /// 返ってくる。**エラーではなく「ここでログが終わり」を意味する**（§6.6）。
    case logRecordEmpty(index: Int)
    /// 1 バイト `00` の通知 = **本体の電源 OFF**（`docs/PROTOCOL.md` §5.1）。
    /// エラーではない。約 0.76 秒後にリンクが supervision timeout で落ちる。
    case powerOff
    case raw(characteristic: UUID, data: Data)
    case connectionState(ConnectionState)
    /// スキャンで見つかっている機器の一覧が**変わった**。
    ///
    /// 同じ機器の広告は 1 秒に何本も届くので、`DiscoveryList.upsert` が
    /// 「中身が変わった」と答えたときだけ流す。
    case discovered(DiscoveryList)
}

/// 生バイト列を `ChronoEvent` へ変換する差し替え可能なデコーダ。
///
/// 実機プロトコルが確定するまでは `PassthroughDecoder` を使い、確定後に
/// `AC6000PacketDecoder`（仮）を追加して差し替える。デコーダは状態を持ってよい
/// （ストリームの分割・結合に対応するため）が、`Sendable` である必要がある。
public protocol ChronoPacketDecoder: Sendable {
    func decode(characteristic: UUID, data: Data) -> [ChronoEvent]
}

/// チェックサム鍵を後から受け取れるデコーダ。
///
/// AC6000 のチェックサムは鍵に依存する（`docs/PROTOCOL.md` §3.1）。鍵はアドバタイズの
/// manufacturer data から取るため、デコーダを作る時点ではまだ分からないことがある。
/// `ChronoDevice` は接続時に鍵が確定したらこの口で流し込む。
public protocol ChronoKeyAwareDecoder: ChronoPacketDecoder {
    func updateKeys(_ keys: DeviceKeys)
}

/// 何も解釈せず `.raw` をそのまま流すデコーダ。プロトコル解析中の既定値。
public struct PassthroughDecoder: ChronoPacketDecoder {
    public init() {}

    public func decode(characteristic: UUID, data: Data) -> [ChronoEvent] {
        [.raw(characteristic: characteristic, data: data)]
    }
}
