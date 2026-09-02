import Foundation

/// AC6000 MKIII BT の既知 opcode。
///
/// 出典は `docs/PROTOCOL.md` §6（実測）と静的解析メモ。**実測で観測されたもの**と
/// **静的解析由来で未検証のもの**をコメントで区別してある。
///
/// > ⚠️ 破壊的・危険な opcode はここに**意図的に含めない**（`docs/PROTOCOL.md` §11）:
/// > `0x61` CLEAR_LOG（本体のログを消す）、`0x24` WRITE_DEVICE_SETTINGS などの
/// > 設定書き込み系。ビルダを用意しなければ誤って送りようがない。
public enum ChronoCommand: UInt8, Sendable, Hashable, CaseIterable {
    /// ACK。payload[0] = 応答対象の cmd。**実測**（`aa 05 41 4b 93`）。
    case ack = 0x41
    /// 鍵の照合 / 取得（READ_KEY / VERIFY_KEY）。TX payload = [key1, key2]。**実測**。
    case readKey = 0x4B
    /// 1 発の計測結果。**実測**（§7）。
    case fireReport = 0x52
    /// 現在選択中の弾。TX payload = [0x00]。**実測**（§6.2）。
    case currentAmmo = 0x5A
    /// アモプリセットの読み出し。TX payload = [0x01, idx]。**実測**（§6.3）。
    case ammoPreset = 0x47
    /// 本体内ログ件数。TX payload = [0x00]。**実測**（§6.5）。
    case logCount = 0x62
    /// ログレコード本体。**未検証**（読み出し方法が未確定なのでビルダは用意しない）。
    case logRecord = 0x63
    /// バッテリー問い合わせ。**未検証**（キャプチャ中 1 度も来なかった）。
    case batteryQuery = 0x2C
    /// バッテリー通知。**未検証**。
    case batteryReport = 0x64
    /// デバイス設定の読み出し。**未検証**（応答レイアウト不明のためビルダは用意しない）。
    case readDeviceSettings = 0x27

    public var name: String {
        switch self {
        case .ack: "ACK"
        case .readKey: "READ_KEY"
        case .fireReport: "FIRE_REPORT"
        case .currentAmmo: "CURRENT_AMMO"
        case .ammoPreset: "AMMO_PRESET"
        case .logCount: "LOG_COUNT"
        case .logRecord: "LOG_RECORD"
        case .batteryQuery: "BATTERY_QUERY"
        case .batteryReport: "BATTERY_REPORT"
        case .readDeviceSettings: "READ_DEVICE_SETTINGS"
        }
    }

    /// ログ表示用。未知 opcode は `0x??` と出す。
    public static func describe(_ cmd: UInt8) -> String {
        ChronoCommand(rawValue: cmd)?.name ?? String(format: "0x%02x", cmd)
    }
}

/// 本キットが送信する読み取り系リクエスト。
///
/// **読み取り専用**。設定書き込み・ログ消去は含めない（`docs/PROTOCOL.md` §11）。
public enum ChronoRequest: Sendable, Hashable {
    /// 鍵の照合。広告 manufacturer data から取った鍵を載せる。
    ///
    /// 鍵が合っていれば数十 ms で `ACK(0x4B)` が返る（実機で確認済み。ボタン押下は不要）。
    /// 鍵が未知のときは `.zero` を載せて送り、本体の電源ボタン押下後に
    /// `0x4B` 応答（data[3], data[4] に鍵）が返るとされる（**未検証**）。
    case readKey(DeviceKeys)
    /// 現在選択中の弾を読む。
    case readCurrentAmmo
    /// 本体内ログ件数を読む。
    case readLogCount
    /// アモプリセット（1..5）を読む。
    case readAmmoPreset(slot: UInt8)
    /// バッテリーを問い合わせる（**未検証**。応答が無くても致命的でない前提で送る）。
    case readBattery

    public var frame: ChronoFrame {
        switch self {
        case .readKey(let keys):
            ChronoFrame(command: .readKey, payload: [keys.key1, keys.key2])
        case .readCurrentAmmo:
            ChronoFrame(command: .currentAmmo, payload: [0x00])
        case .readLogCount:
            ChronoFrame(command: .logCount, payload: [0x00])
        case .readAmmoPreset(let slot):
            ChronoFrame(command: .ammoPreset, payload: [0x01, slot])
        case .readBattery:
            ChronoFrame(command: .batteryQuery, payload: [0x00])
        }
    }

    /// 送信バイト列。
    ///
    /// **`READ_KEY` だけは鍵確立前のフレームなので、`keys` に関わらず 0/0 で署名する**
    /// （`docs/PROTOCOL.md` §3.2 の worked example と一致）。この特例をここ 1 箇所に
    /// 閉じ込めることで、呼び出し側が鍵の有無を気にしなくてよくなる。
    public func encoded(keys: DeviceKeys) -> Data {
        switch self {
        case .readKey:
            frame.encode(keys: .zero)
        default:
            frame.encode(keys: keys)
        }
    }
}

extension ChronoCommand {
    // 仕様書の呼び名でそのまま呼べる薄いショートカット。

    /// `aa 06 4b <k1> <k2> <cks>`（鍵 0/0 で署名）。
    public static func readKey(keys: DeviceKeys) -> Data {
        ChronoRequest.readKey(keys).encoded(keys: keys)
    }

    /// `aa 05 5a 00 <cks>`
    public static func readCurrentAmmo(keys: DeviceKeys) -> Data {
        ChronoRequest.readCurrentAmmo.encoded(keys: keys)
    }

    /// `aa 05 62 00 <cks>`
    public static func readLogCount(keys: DeviceKeys) -> Data {
        ChronoRequest.readLogCount.encoded(keys: keys)
    }

    /// `aa 06 47 01 <n> <cks>`
    public static func readAmmoPreset(_ slot: UInt8, keys: DeviceKeys) -> Data {
        ChronoRequest.readAmmoPreset(slot: slot).encoded(keys: keys)
    }

    /// `aa 05 2c 00 <cks>`（**未検証**）
    public static func readBattery(keys: DeviceKeys) -> Data {
        ChronoRequest.readBattery.encoded(keys: keys)
    }
}
