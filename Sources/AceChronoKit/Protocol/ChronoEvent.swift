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

    /// 直径（mm）。スケールは**推定**。
    public var diameterMm: Double { Double(rawDiameter) / 100.0 }
    /// 重量（g）。スケールは**推定**。
    public var weightGrams: Double { Double(rawWeight) / 100.0 }
}

/// 弾速計から流れてくるアプリ向けのイベント。
///
/// `ChronoPacketDecoder` が生バイト列をこれに変換し、`ChronoDevice` が
/// `AsyncStream<ChronoEvent>` として配信する。
public enum ChronoEvent: Sendable {
    case shot(Shot)
    case battery(percent: Int)
    case deviceInfo(model: String, firmware: String?)
    /// `0x41` ACK。`command` は応答対象の cmd（ハンドシェイクでは `0x4B`）。
    case ack(command: UInt8)
    /// 弾の設定（`0x5A` / `0x47`）。**要求していなくても本体から自発的に飛んでくる**。
    case ammo(AmmoRecord)
    /// 本体内のログ件数（`0x62`）。
    case logCount(Int)
    /// 1 バイト `00` の通知 = **本体の電源 OFF**（`docs/PROTOCOL.md` §5.1）。
    /// エラーではない。約 0.76 秒後にリンクが supervision timeout で落ちる。
    case powerOff
    case raw(characteristic: UUID, data: Data)
    case connectionState(ConnectionState)
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
