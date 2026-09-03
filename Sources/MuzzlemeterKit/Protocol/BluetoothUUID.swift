import Foundation

/// Bluetooth の 16bit / 32bit 短縮 UUID を 128bit の `Foundation.UUID` に正規化する。
///
/// `MuzzlemeterKit` は CoreBluetooth に依存しない（テスト・Linux・将来の別トランスポートのため）。
/// そのため characteristic の識別子は `CBUUID` ではなく `UUID` で扱い、
/// `"FFE1"` のような短縮表記はここで Bluetooth Base UUID
/// `0000xxxx-0000-1000-8000-00805F9B34FB` に展開する。
public enum BluetoothUUID {
    /// Bluetooth Base UUID のサフィックス。
    public static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// `"FFE1"` / `"0000FFE1"` / 完全な 128bit 文字列を `UUID` に変換する。
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

    /// 16bit 短縮 UUID から `UUID` を作る。
    public static func short(_ value: UInt16) -> UUID {
        // 16bit 値は必ず有効な Base UUID になるため、失敗しない。
        parse(String(format: "%04X", value)) ?? UUID()
    }

    /// Bluetooth Base UUID に属する場合、短縮表記（`"FFE1"`）を返す。そうでなければ完全表記。
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

/// hex 文字列 ⇄ `Data`。リプレイスクリプトとログの読み書きに使う。
public enum HexBytes {
    /// `"aa 55 01"` / `"aa5501"` / `"0xAA,0x55"` を `Data` に変換する。
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

    /// `Data` を `"aa 55 01"` に整形する。
    public static func string(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
