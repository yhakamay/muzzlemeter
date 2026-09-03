import CoreBluetooth
import Foundation

// MARK: - バイト列の整形

enum Hex {
    /// `Data` を "0a 1b 2c" 形式に整形する。
    static func string(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// 表示可能 ASCII のみを残し、それ以外を "." に置き換える。
    static func ascii(_ data: Data) -> String {
        String(data.map { byte in
            (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "."
        })
    }

    /// "0a1b2c" / "0a 1b 2c" / "0x0a,0x1b" などを `Data` に変換する。
    static func parse(_ text: String) -> Data? {
        var cleaned = text.lowercased()
        for token in ["0x", " ", ",", ":", "-", "_"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
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
}

// MARK: - UUID ユーティリティ

enum UUIDText {
    /// 16bit / 32bit の短縮 UUID を 128bit の正規形に揃える（比較用）。
    static func canonical(_ uuid: CBUUID) -> String {
        canonical(uuid.uuidString)
    }

    static func canonical(_ text: String) -> String {
        let upper = text.uppercased()
        switch upper.count {
        case 4: return "0000\(upper)-0000-1000-8000-00805F9B34FB"
        case 8: return "\(upper)-0000-1000-8000-00805F9B34FB"
        default: return upper
        }
    }

    /// `CBUUID(string:)` は不正な文字列で ObjC 例外を投げて即死するため、事前に検証する。
    static func makeCBUUID(_ text: String) -> CBUUID? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        switch trimmed.count {
        case 4, 8:
            guard trimmed.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else { return nil }
            return CBUUID(string: trimmed)
        case 36:
            guard UUID(uuidString: trimmed) != nil else { return nil }
            return CBUUID(string: trimmed)
        default:
            return nil
        }
    }
}

// MARK: - Characteristic プロパティ

extension CBCharacteristicProperties {
    var descriptions: [String] {
        var out = [String]()
        if contains(.broadcast) { out.append("broadcast") }
        if contains(.read) { out.append("read") }
        if contains(.writeWithoutResponse) { out.append("writeWithoutResponse") }
        if contains(.write) { out.append("write") }
        if contains(.notify) { out.append("notify") }
        if contains(.indicate) { out.append("indicate") }
        if contains(.authenticatedSignedWrites) { out.append("authenticatedSignedWrites") }
        if contains(.extendedProperties) { out.append("extendedProperties") }
        if contains(.notifyEncryptionRequired) { out.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { out.append("indicateEncryptionRequired") }
        return out
    }
}

// MARK: - ログ出力

/// stdout と（指定されていれば）ログファイルの両方へ 1 行書き出す。
final class LogWriter: @unchecked Sendable {
    private let handle: FileHandle?
    let path: String?

    init(path: String?) {
        self.path = path
        guard let path else {
            self.handle = nil
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        self.handle = handle
    }

    func log(_ line: String) {
        print(line)
        if let handle, let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    func close() {
        try? handle?.close()
    }
}

// MARK: - タイムスタンプ

enum Timestamp {
    /// ミリ秒付き ISO8601（ローカルタイムゾーン）。
    static func iso8601(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func fileStamp(_ date: Date) -> String {
        fileFormatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
