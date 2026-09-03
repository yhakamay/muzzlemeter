import Foundation

/// Normalizes Bluetooth 16-bit / 32-bit short UUIDs into a 128-bit `Foundation.UUID`.
///
/// `MuzzlemeterKit` doesn't depend on CoreBluetooth (for testing, Linux, and future
/// alternate transports). Because of that, characteristic identifiers are handled as
/// `UUID` rather than `CBUUID`, and a short form like `"FFE1"` is expanded here to the
/// Bluetooth Base UUID `0000xxxx-0000-1000-8000-00805F9B34FB`.
public enum BluetoothUUID {
    /// The suffix of the Bluetooth Base UUID.
    public static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Converts `"FFE1"` / `"0000FFE1"` / a full 128-bit string into a `UUID`.
    public static func parse(_ text: String) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch trimmed.count {
        case 4:
            guard isHex(trimmed) else { return nil }
            return UUID(uuidString: "0000\(trimmed)\(baseSuffix)")
        case 8:
            guard isHex(trimmed) else { return nil }
            return UUID(uuidString: "\(trimmed)\(baseSuffix)")
        default:
            return UUID(uuidString: trimmed)
        }
    }

    /// Builds a `UUID` from a 16-bit short UUID value.
    public static func short(_ value: UInt16) -> UUID {
        // A 16-bit value always produces a valid Base UUID, so this never fails.
        parse(String(format: "%04X", value)) ?? UUID()
    }

    /// Returns the short form (`"FFE1"`) if the UUID belongs to the Bluetooth Base UUID
    /// range, otherwise the full form.
    public static func displayString(_ uuid: UUID) -> String {
        let text = uuid.uuidString.uppercased()
        guard text.hasSuffix(baseSuffix.uppercased()),
              text.hasPrefix("0000")
        else { return text }
        let start = text.index(text.startIndex, offsetBy: 4)
        let end = text.index(text.startIndex, offsetBy: 8)
        return String(text[start..<end])
    }

    private static func isHex(_ text: String) -> Bool {
        text.allSatisfy(\.isHexDigit)
    }
}

/// Hex string <-> `Data` conversion. Used when reading and writing replay scripts and logs.
public enum HexBytes {
    /// Converts `"aa 55 01"` / `"aa5501"` / `"0xAA,0x55"` into `Data`.
    public static func parse(_ text: String) -> Data? {
        var cleaned = text.lowercased()
        for token in ["0x", " ", "\t", ",", ":", "-", "_"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Formats `Data` as `"aa 55 01"`.
    public static func string(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
