import Foundation

/// スキャンで見つかった機器。
public struct DiscoveredPeripheral: Sendable, Hashable, Identifiable, Codable {
    /// CoreBluetooth の `CBPeripheral.identifier`（この Mac / iPhone 内でのみ安定な UUID）。
    public let id: UUID
    public let name: String?
    /// 受信信号強度（dBm）。不明なら `nil`。
    public let rssi: Int?
    /// アドバタイズされていたサービス UUID。
    public let advertisedServices: [UUID]

    public init(id: UUID, name: String?, rssi: Int? = nil, advertisedServices: [UUID] = []) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServices = advertisedServices
    }

    public var displayName: String { name ?? id.uuidString }
}

/// トランスポート層（BLE そのもの）から上がってくる、プロトコル解釈前の生イベント。
public enum TransportEvent: Sendable {
    case discovered(DiscoveredPeripheral)
    case connected(peripheral: UUID)
    case disconnected(peripheral: UUID, reason: String?)
    /// notify / indicate / read で受け取った値。
    case value(characteristic: UUID, data: Data)
    /// 購読が確立した。
    case subscribed(characteristic: UUID)
    /// 復帰可能なエラー（接続失敗など）。致命的なものは `throws` で返す。
    case failed(reason: String)
}

public enum ChronoTransportError: Error, Sendable, Equatable {
    case notConnected
    case unavailable(String)
    case unknownCharacteristic(UUID)
    case writeNotSupported(UUID)
}

/// BLE の実体を隠す抽象。
///
/// 実装は 2 つを想定している:
/// - `CoreBluetoothTransport`（未実装。実機の service / characteristic UUID が
///   確定してから `Sources/AceChronoSniff/BLESniffer.swift` の CoreBluetooth コードを
///   ここへ移す。デリゲートは専用キュー上で動くので actor でラップする）
/// - `ReplayTransport`（記録済みパケットの再生。シミュレータ・Preview・テスト用）
///
/// 全メソッドを `async` にしてあるのは、実装を `actor` にできるようにするため。
public protocol ChronoTransport: Sendable {
    /// トランスポートイベントの配信ストリーム。**単一コンシューマ**を想定している
    /// （`ChronoDevice` が 1 つだけ購読する）。
    var events: AsyncStream<TransportEvent> { get async }

    /// スキャンを開始する。`services` / `nameFilter` が `nil` なら絞り込まない。
    func scan(services: [UUID]?, nameFilter: String?) async throws
    func stopScan() async
    func connect(to peripheral: UUID) async throws
    func disconnect() async
    func subscribe(to characteristic: UUID) async throws
    func write(_ data: Data, to characteristic: UUID, withResponse: Bool) async throws
    /// 購読と初期化書き込みがすべて終わったことを知らせる。
    ///
    /// 実 BLE では何もしない（notify は `subscribe` の時点で始まっている）。
    /// `ReplayTransport` はここで再生を開始する。これがあることで
    /// 「購読を全部終える前に最初のパケットが流れてしまう」競合が構造的に起きない。
    func finishSetup() async
    /// イベントストリームを終了し、内部リソースを解放する。以降このインスタンスは使えない。
    func shutdown() async
}

extension ChronoTransport {
    public func finishSetup() async {}
}
