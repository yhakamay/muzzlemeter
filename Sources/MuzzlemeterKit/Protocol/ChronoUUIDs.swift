import Foundation

/// The AC6000 MKIII BT's BLE service / characteristic UUIDs.
///
/// These values are **confirmed** per `docs/PROTOCOL.md` §2 (a GATT table measured from
/// an Apple PacketLogger capture). **Notify and Write live in separate services**, so
/// don't discover them as if they were in one.
public enum ChronoUUIDs {
    // MARK: - Notify (device -> app)

    /// The notify service (handles 0x000E-0x0011).
    public static let notifyService = uuid("5CDE0C3D-7B1D-4352-94BB-02269C9F42B5")
    /// The notification characteristic (handle 0x0010, properties 0x10 = Notify only).
    public static let notifyCharacteristic = uuid("3337E46E-F79E-4FF5-9A49-77C36D170C62")

    // MARK: - Write (app -> device)

    /// The write service (handles 0x0012-0x0014).
    public static let writeService = uuid("53C47FE1-6C22-4EA6-99C7-7B6325EC75B9")
    /// The write characteristic (handle 0x0014, properties 0x0C).
    ///
    /// Write Without Response is also declared, but AceSoft sends every frame as an
    /// **ATT Write Request (with response)** (`docs/PROTOCOL.md` §3.4). This kit writes
    /// `withResponse` too.
    public static let writeCharacteristic = uuid("9C6AA1EE-B4B9-44A1-BA45-1558C9109B4C")

    // MARK: - OTA (never touch this)

    /// The Silicon Labs OTA (DFU) service. **Discovery only. Writing is forbidden.**
    public static let otaService = uuid("1D14D6EE-FD63-4FA1-BFA4-8F47B42119F0")

    /// Do not write to this. Ever.
    ///
    /// The Silicon Labs OTA control point (handle 0x0017). Writing here reboots the MCU
    /// into the OTA bootloader, and recovery requires a genuine firmware image (i.e.
    /// **bricking risk**). See `docs/PROTOCOL.md` §11.
    ///
    /// `CoreBluetoothTransport` restricts write targets to an allowlist and rejects a
    /// write to this UUID with `ChronoTransportError.forbiddenCharacteristic`.
    public static let otaControlCharacteristic = uuid("F7BF3564-FB6D-4E53-88A4-5E37E0326063")

    /// Characteristics that writes are forbidden to. Transport implementations must
    /// always consult this.
    public static let forbiddenWriteCharacteristics: Set<UUID> = [otaControlCharacteristic]

    /// Whether writing to this characteristic is forbidden.
    public static func isForbiddenWriteTarget(_ characteristic: UUID) -> Bool {
        forbiddenWriteCharacteristics.contains(characteristic)
    }

    // MARK: - Scanning

    /// Prefix-match candidates for the advertised Complete Local Name.
    ///
    /// Confirmed on real hardware: `AC6000BT-009809`. Other spellings for AC6000/AC7000
    /// also show up in reference material, so they're included as candidates too. The GAP
    /// Device Name (0x2A00) may be `ACETECH-12345678` on every unit and can't be used to
    /// identify a specific device.
    public static let advertisedNamePrefixes = ["AC6000BT-", "AC6000-BT", "AC7000-BT"]

    /// The name filter used when scanning (the default for
    /// `ChronoDevice.Configuration.nameFilter`).
    public static let primaryNamePrefix = "AC6000BT-"

    /// The first 3 bytes of the Manufacturer Specific Data (company id `00 05` + model
    /// code `08`). Used as a fallback to catch advertisements where the name can't be read.
    public static let manufacturerDataPrefix: [UInt8] = [0x00, 0x05, 0x08]

    /// **No service UUID is advertised** (confirmed by measurement). Scan with
    /// `services: nil` and filter by name / manufacturer data instead.
    public static let advertisesServiceUUIDs = false

    /// Whether the advertised name belongs to the AC6000 family.
    public static func matchesAdvertisedName(_ name: String?) -> Bool {
        guard let name else { return false }
        let upper = name.uppercased()
        return advertisedNamePrefixes.contains { upper.hasPrefix($0.uppercased()) }
    }

    /// Whether the manufacturer data belongs to the AC6000 family (`00 05 08 ...`).
    public static func matchesManufacturerData(_ data: Data?) -> Bool {
        guard let data, data.count >= manufacturerDataPrefix.count else { return false }
        return Array(data.prefix(manufacturerDataPrefix.count)) == manufacturerDataPrefix
    }

    /// Whether the advertisement belongs to the AC6000 family (matched by name **or**
    /// manufacturer data).
    public static func matches(name: String?, manufacturerData: Data?) -> Bool {
        matchesAdvertisedName(name) || matchesManufacturerData(manufacturerData)
    }

    /// Builds a `UUID` from a string literal. Never fails since every constant here is a
    /// valid UUID.
    private static func uuid(_ text: String) -> UUID {
        guard let value = UUID(uuidString: text) else {
            preconditionFailure("Invalid UUID literal in ChronoUUIDs: \(text)")
        }
        return value
    }
}

/// The 2-byte key added into a frame's checksum.
///
/// `docs/PROTOCOL.md` §3.1 / §4.3:
/// * The checksum is `(sum(frame[0..L-2]) + key1 + key2) & 0xFF`.
/// * The key is carried at offset 3/4 of the advertisement's Manufacturer Specific Data
///   (`00 05 08 c4 94 52 04` -> key1 = 0xC4, key2 = 0x94). **Verified on real hardware**:
///   putting the key straight from the advertisement into `0x4B` gets an ACK back in
///   55 ms, with no button press needed on the device.
/// * The `0x4B` (READ_KEY) frame itself is signed with `key1 = key2 = 0`, since the key
///   isn't established yet at that point.
public struct DeviceKeys: Sendable, Hashable, Codable, CustomStringConvertible {
    public let key1: UInt8
    public let key2: UInt8

    public init(key1: UInt8, key2: UInt8) {
        self.key1 = key1
        self.key2 = key2
    }

    /// 0/0, representing "no key established yet." Also used to sign the READ_KEY frame.
    public static let zero = DeviceKeys(key1: 0, key2: 0)

    public var isZero: Bool { key1 == 0 && key2 == 0 }

    /// The value added into the checksum.
    public var sum: Int { Int(key1) + Int(key2) }

    /// Extracts the key from the advertisement's Manufacturer Specific Data.
    ///
    /// `00 05 08 c4 94 52 04`
    ///  |--|  |-| |-| |-|
    ///   |     |   |   `- key2 (offset 4)
    ///   |     |   `----- key1 (offset 3)
    ///   |     `--------- model code (inferred)
    ///   `--------------- company id (LE 0x0500; not an official SIG assignment)
    ///
    /// `nil` if the company id isn't `00 05`, or the data is under 5 bytes.
    public init?(manufacturerData: Data) {
        let bytes = [UInt8](manufacturerData)
        guard bytes.count >= 5 else { return nil }
        guard bytes[0] == 0x00, bytes[1] == 0x05 else { return nil }
        self.init(key1: bytes[3], key2: bytes[4])
    }

    /// The `"c494"` form, used when persisting to `KeyValueStore`.
    public var hexString: String { String(format: "%02x%02x", key1, key2) }

    public init?(hexString: String) {
        guard let data = HexBytes.parse(hexString), data.count == 2 else { return nil }
        self.init(key1: data[data.startIndex], key2: data[data.index(after: data.startIndex)])
    }

    public var description: String { "key1=0x\(String(format: "%02x", key1)) key2=0x\(String(format: "%02x", key2))" }
}
