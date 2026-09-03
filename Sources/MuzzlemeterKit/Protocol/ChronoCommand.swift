import Foundation

/// Known opcodes for the AC6000 MKIII BT.
///
/// Sourced from `docs/PROTOCOL.md` §6. Comments distinguish between **what's been
/// confirmed by measurement** and **what hasn't been observed yet (unverified)**.
///
/// > Warning: destructive / dangerous opcodes are **deliberately excluded** here
/// > (`docs/PROTOCOL.md` §11): `0x61` CLEAR_LOG (erases the device's log), `0x24`
/// > WRITE_DEVICE_SETTINGS, and other settings-writing commands. Without a builder for
/// > them, they can't be sent by accident.
public enum ChronoCommand: UInt8, Sendable, Hashable, CaseIterable {
    /// ACK. payload[0] = the cmd being acknowledged. **Confirmed by measurement**
    /// (`aa 05 41 4b 93`).
    case ack = 0x41
    /// NAK. The response to an unknown command. payload is fixed at `0xFF`. The
    /// rejection counterpart to ACK (`0x41`). **Confirmed on real hardware**
    /// (`aa 05 4e ff 54`. `docs/PROTOCOL.md` §6.7).
    case nak = 0x4E
    /// Key verification / retrieval (READ_KEY / VERIFY_KEY). TX payload = [key1, key2].
    /// **Confirmed by measurement**.
    case readKey = 0x4B
    /// One shot's measurement result. **Confirmed by measurement** (§7).
    case fireReport = 0x52
    /// The currently selected BB. TX payload = [0x00]. **Confirmed by measurement**
    /// (§6.2).
    case currentAmmo = 0x5A
    /// Reads an ammo preset. TX payload = [0x01, idx]. **Confirmed by measurement**
    /// (§6.3).
    case ammoPreset = 0x47
    /// The device log's record count. TX payload = [0x00]. **Confirmed on real
    /// hardware** (§6.5): RX payload = [count, 0x01] (`count` = number of records,
    /// including 0. The second byte is always `0x01`; its meaning is unknown and it's
    /// kept as-is). This log is **volatile** (resets to 0 records when the device is
    /// powered off).
    case logCount = 0x62
    /// One log record. TX payload = [index] (1 byte, **1-based**). **Confirmed on real
    /// hardware** (§6.6). RX payload = [index, rev0, rev1, speed0, speed1] (5 bytes).
    /// A request for index 0 gets no response. An index past the record count returns an
    /// all-zero record (not an error — it signals "that's the end").
    case logRecord = 0x63
    /// Battery query. **Unverified** (never seen in any capture).
    case batteryQuery = 0x2C
    /// Battery report. **Unverified**.
    case batteryReport = 0x64
    /// Reads device settings. **Unverified** (no builder provided, since the response
    /// layout is unknown).
    case readDeviceSettings = 0x27

    public var name: String {
        switch self {
        case .ack: "ACK"
        case .nak: "NAK"
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

    /// For log display. An unknown opcode is shown as `0x??`.
    public static func describe(_ cmd: UInt8) -> String {
        ChronoCommand(rawValue: cmd)?.name ?? String(format: "0x%02x", cmd)
    }
}

/// The read-only requests this kit sends.
///
/// **Read-only.** Settings writes and log erasure are intentionally not included
/// (`docs/PROTOCOL.md` §11).
public enum ChronoRequest: Sendable, Hashable {
    /// Verifies the key. Carries the key taken from the advertisement's manufacturer
    /// data.
    ///
    /// If the key is correct, `ACK(0x4B)` comes back within tens of ms (confirmed on
    /// real hardware; no button press needed). When the key is unknown, this is sent
    /// with `.zero`, and the device is said to respond with `0x4B` (key in data[3],
    /// data[4]) after the power button is pressed (**unverified**).
    case readKey(DeviceKeys)
    /// Reads the currently selected BB.
    case readCurrentAmmo
    /// Reads the device log's record count.
    case readLogCount
    /// Reads one device log record (`0x63`). **Confirmed on real hardware**
    /// (`docs/PROTOCOL.md` §6.6).
    ///
    /// The payload is a 1-byte, **1-based** index. Index 0 gets no response. An index
    /// past the record count returns an all-zero record (not an error).
    case readLogRecord(index: UInt8)
    /// Reads an ammo preset (1..5).
    case readAmmoPreset(slot: UInt8)
    /// Queries the battery (**unverified**; sent on the assumption that no response
    /// isn't fatal).
    case readBattery

    public var frame: ChronoFrame {
        switch self {
        case .readKey(let keys):
            ChronoFrame(command: .readKey, payload: [keys.key1, keys.key2])
        case .readCurrentAmmo:
            ChronoFrame(command: .currentAmmo, payload: [0x00])
        case .readLogCount:
            ChronoFrame(command: .logCount, payload: [0x00])
        case .readLogRecord(let index):
            ChronoFrame(command: .logRecord, payload: [index])
        case .readAmmoPreset(let slot):
            ChronoFrame(command: .ammoPreset, payload: [0x01, slot])
        case .readBattery:
            ChronoFrame(command: .batteryQuery, payload: [0x00])
        }
    }

    /// The bytes to transmit.
    ///
    /// **`READ_KEY` alone is signed with 0/0 regardless of `keys`**, since it's sent
    /// before the key is established (matching the worked example in
    /// `docs/PROTOCOL.md` §3.2). Keeping this special case in this one place means
    /// callers don't have to worry about whether the key is known yet.
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
    // Thin shortcuts callable by the names used in the spec.

    /// `aa 06 4b <k1> <k2> <cks>` (signed with key 0/0).
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

    /// `aa 05 63 <index> <cks>` (1-byte, 1-based index. **Confirmed on real hardware.**
    /// §6.6)
    public static func readLogRecord(_ index: UInt8, keys: DeviceKeys) -> Data {
        ChronoRequest.readLogRecord(index: index).encoded(keys: keys)
    }

    /// `aa 06 47 01 <n> <cks>`
    public static func readAmmoPreset(_ slot: UInt8, keys: DeviceKeys) -> Data {
        ChronoRequest.readAmmoPreset(slot: slot).encoded(keys: keys)
    }

    /// `aa 05 2c 00 <cks>` (**unverified**)
    public static func readBattery(keys: DeviceKeys) -> Data {
        ChronoRequest.readBattery.encoded(keys: keys)
    }
}
