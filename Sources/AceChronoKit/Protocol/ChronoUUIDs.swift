import Foundation

/// AC6000 MKIII BT の BLE サービス / キャラクタリスティック UUID。
///
/// 値は `docs/PROTOCOL.md` §2（Apple PacketLogger の実測 GATT テーブル）に基づく **確定値**。
/// **Notify と Write は別サービスにある**ので、1 サービスにまとめて探索してはいけない。
public enum ChronoUUIDs {
    // MARK: - Notify（本体 → アプリ）

    /// Notify サービス（handles 0x000E–0x0011）。
    public static let notifyService = uuid("5CDE0C3D-7B1D-4352-94BB-02269C9F42B5")
    /// 通知用 characteristic（handle 0x0010、properties 0x10 = Notify のみ）。
    public static let notifyCharacteristic = uuid("3337E46E-F79E-4FF5-9A49-77C36D170C62")

    // MARK: - Write（アプリ → 本体）

    /// Write サービス（handles 0x0012–0x0014）。
    public static let writeService = uuid("53C47FE1-6C22-4EA6-99C7-7B6325EC75B9")
    /// 書き込み用 characteristic（handle 0x0014、properties 0x0C）。
    ///
    /// Write Without Response も申告されているが、AceSoft は全フレームを
    /// **ATT Write Request（応答あり）**で送っている（`docs/PROTOCOL.md` §3.4）。
    /// 本キットも `withResponse` で送る。
    public static let writeCharacteristic = uuid("9C6AA1EE-B4B9-44A1-BA45-1558C9109B4C")

    // MARK: - OTA（絶対に触らない）

    /// Silicon Labs OTA（DFU）サービス。**列挙のみ。書き込み禁止。**
    public static let otaService = uuid("1D14D6EE-FD63-4FA1-BFA4-8F47B42119F0")

    /// 🚫 **絶対に書き込まないこと。**
    ///
    /// Silicon Labs OTA コントロール（handle 0x0017）。ここへ書き込むと MCU が
    /// OTA ブートローダへ再起動し、復旧には正規のファームウェアイメージが要る
    /// （＝**文鎮化のリスク**）。`docs/PROTOCOL.md` §11 を参照。
    ///
    /// `CoreBluetoothTransport` は書き込み先をホワイトリストで縛り、この UUID への
    /// 書き込みを `ChronoTransportError.forbiddenCharacteristic` で拒否する。
    public static let otaControlCharacteristic = uuid("F7BF3564-FB6D-4E53-88A4-5E37E0326063")

    /// 書き込みを禁じる characteristic。トランスポート実装はここを必ず参照する。
    public static let forbiddenWriteCharacteristics: Set<UUID> = [otaControlCharacteristic]

    /// この characteristic への書き込みが禁止されているか。
    public static func isForbiddenWriteTarget(_ characteristic: UUID) -> Bool {
        forbiddenWriteCharacteristics.contains(characteristic)
    }

    // MARK: - スキャン

    /// アドバタイズされる Complete Local Name の前方一致候補。
    ///
    /// 実測は `AC6000BT-009809`。AC6000/AC7000 の別表記も資料に現れるため候補に含める。
    /// GAP Device Name（0x2A00）は全個体で `ACETECH-12345678` の可能性があり識別に使えない。
    public static let advertisedNamePrefixes = ["AC6000BT-", "AC6000-BT", "AC7000-BT"]

    /// スキャン時の名前フィルタ（`ChronoDevice.Configuration.nameFilter` の既定値）。
    public static let primaryNamePrefix = "AC6000BT-"

    /// Manufacturer Specific Data の先頭 3 バイト（company id `00 05` + 機種コード `08`）。
    /// 名前が取れないアドバタイズを拾うための保険として使う。
    public static let manufacturerDataPrefix: [UInt8] = [0x00, 0x05, 0x08]

    /// **サービス UUID はアドバタイズされない**（実測）。スキャンは `services: nil` で行い、
    /// 名前 / manufacturer data で絞ること。
    public static let advertisesServiceUUIDs = false

    /// 広告名が AC6000 系か。
    public static func matchesAdvertisedName(_ name: String?) -> Bool {
        guard let name else { return false }
        let upper = name.uppercased()
        return advertisedNamePrefixes.contains { upper.hasPrefix($0.uppercased()) }
    }

    /// Manufacturer data が AC6000 系か（`00 05 08 …`）。
    public static func matchesManufacturerData(_ data: Data?) -> Bool {
        guard let data, data.count >= manufacturerDataPrefix.count else { return false }
        return Array(data.prefix(manufacturerDataPrefix.count)) == manufacturerDataPrefix
    }

    /// 広告が AC6000 系のものか（名前 **または** manufacturer data で判定）。
    public static func matches(name: String?, manufacturerData: Data?) -> Bool {
        matchesAdvertisedName(name) || matchesManufacturerData(manufacturerData)
    }

    /// 文字列リテラルからの生成。定数はすべて有効な UUID なので失敗しない。
    private static func uuid(_ text: String) -> UUID {
        guard let value = UUID(uuidString: text) else {
            preconditionFailure("ChronoUUIDs の UUID リテラルが不正です: \(text)")
        }
        return value
    }
}

/// フレームのチェックサムに加算される 2 バイトの鍵。
///
/// `docs/PROTOCOL.md` §3.1 / §4.3:
/// * チェックサムは `(Σ frame[0..L-2] + key1 + key2) & 0xFF`。
/// * 鍵はアドバタイズの Manufacturer Specific Data の offset 3/4 に載っている
///   （`00 05 08 c4 94 52 04` → key1 = 0xC4, key2 = 0x94）。**実機で検証済み**:
///   広告から取った鍵をそのまま `0x4B` に載せると 55 ms で ACK が返り、
///   本体の電源ボタン押下は不要だった。
/// * `0x4B`（READ_KEY）フレーム自身だけは鍵確立前なので `key1 = key2 = 0` で署名する。
public struct DeviceKeys: Sendable, Hashable, Codable, CustomStringConvertible {
    public let key1: UInt8
    public let key2: UInt8

    public init(key1: UInt8, key2: UInt8) {
        self.key1 = key1
        self.key2 = key2
    }

    /// 鍵未確立を表す 0/0。READ_KEY フレームの署名にも使う。
    public static let zero = DeviceKeys(key1: 0, key2: 0)

    public var isZero: Bool { key1 == 0 && key2 == 0 }

    /// チェックサムに加算する値。
    public var sum: Int { Int(key1) + Int(key2) }

    /// アドバタイズの Manufacturer Specific Data から鍵を取り出す。
    ///
    /// `00 05 08 c4 94 52 04`
    ///  └┬─┘ └┬┘ └┬┘ └┬┘
    ///   │    │   │   └ key2 (offset 4)
    ///   │    │   └──── key1 (offset 3)
    ///   │    └──────── 機種コード（推定）
    ///   └───────────── company id（LE 0x0500。SIG の正規割り当てではない）
    ///
    /// company id が `00 05` でない、または 5 バイト未満なら `nil`。
    public init?(manufacturerData: Data) {
        let bytes = [UInt8](manufacturerData)
        guard bytes.count >= 5 else { return nil }
        guard bytes[0] == 0x00, bytes[1] == 0x05 else { return nil }
        self.init(key1: bytes[3], key2: bytes[4])
    }

    /// `"c494"` 形式。`KeyValueStore` への永続化に使う。
    public var hexString: String { String(format: "%02x%02x", key1, key2) }

    public init?(hexString: String) {
        guard let data = HexBytes.parse(hexString), data.count == 2 else { return nil }
        self.init(key1: data[data.startIndex], key2: data[data.index(after: data.startIndex)])
    }

    public var description: String { "key1=0x\(String(format: "%02x", key1)) key2=0x\(String(format: "%02x", key2))" }
}
