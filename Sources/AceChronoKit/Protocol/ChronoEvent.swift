import Foundation

/// 弾速計との接続状態。
///
/// `pairing` は AceSoft が接続直後に鍵ハンドシェイク（`docs/PROTOCOL-apk-analysis.md` §5）を
/// 行うことが判明しているため、その段階を表現できるよう先に用意してある。
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

/// 弾速計から流れてくるアプリ向けのイベント。
///
/// `ChronoPacketDecoder` が生バイト列をこれに変換し、`ChronoDevice` が
/// `AsyncStream<ChronoEvent>` として配信する。パケット形式が未確定の現時点では
/// `PassthroughDecoder` が `.raw` だけを流す。
public enum ChronoEvent: Sendable {
    case shot(Shot)
    case battery(percent: Int)
    case deviceInfo(model: String, firmware: String?)
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

/// 何も解釈せず `.raw` をそのまま流すデコーダ。プロトコル解析中の既定値。
public struct PassthroughDecoder: ChronoPacketDecoder {
    public init() {}

    public func decode(characteristic: UUID, data: Data) -> [ChronoEvent] {
        [.raw(characteristic: characteristic, data: data)]
    }
}
