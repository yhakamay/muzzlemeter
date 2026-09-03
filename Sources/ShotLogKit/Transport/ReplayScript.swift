import Foundation

/// リプレイスクリプトの 1 行 = ある時刻に届いた 1 パケット。
public struct ReplayEntry: Sendable, Hashable {
    /// スクリプト先頭からの経過秒。
    public let offsetSeconds: TimeInterval
    public let characteristic: UUID
    public let data: Data

    public init(offsetSeconds: TimeInterval, characteristic: UUID, data: Data) {
        self.offsetSeconds = offsetSeconds
        self.characteristic = characteristic
        self.data = data
    }
}

public enum ReplayScriptError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedLine(number: Int, text: String)
    case badUUID(number: Int, text: String)
    case badHex(number: Int, text: String)

    public var description: String {
        switch self {
        case .malformedLine(let n, let t): "line \(n): 書式が不正です: \(t)"
        case .badUUID(let n, let t): "line \(n): UUID が不正です: \(t)"
        case .badHex(let n, let t): "line \(n): hex が不正です: \(t)"
        }
    }
}

/// 記録済みパケット列。`ReplayTransport` が時間軸どおりに再生する。
///
/// 2 つのテキスト形式を読める。
///
/// **1. 手書き用の簡易形式** — 先頭が `+` の行:
/// ```
/// +0     FFE1  a0 23 00 00
/// +1500  FFE1  b4 23 00 00
/// ```
/// `+<ミリ秒>` は**スクリプト先頭からの絶対オフセット**。`#` 始まりと空行は無視。
///
/// **2. `shotlog-sniff dump` のログ形式** — そのまま読み込める:
/// ```
/// [2026-09-02T22:31:04.512+09:00] [+412.7 ms] FFE1 len=8 hex: aa 55 01 5a ascii: .U.Z
/// ```
/// オフセットは ISO8601 タイムスタンプの差（最初のパケット行を 0 とする）。
/// タイムスタンプが読めない行では `[+N ms]` の差分を積み上げる。
/// パケット行以外（GATT ツリー・`write ->`・`read ` などのログ行）は読み飛ばす。
public struct ReplayScript: Sendable, Hashable {
    public var entries: [ReplayEntry]

    public init(entries: [ReplayEntry]) {
        self.entries = entries.sorted { $0.offsetSeconds < $1.offsetSeconds }
    }

    public var duration: TimeInterval { entries.last?.offsetSeconds ?? 0 }

    /// スクリプトに現れる characteristic の一覧（重複なし・出現順）。
    public var characteristics: [UUID] {
        var seen = Set<UUID>()
        var result = [UUID]()
        for entry in entries where seen.insert(entry.characteristic).inserted {
            result.append(entry.characteristic)
        }
        return result
    }

    public static func load(contentsOf url: URL) throws -> ReplayScript {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> ReplayScript {
        var entries = [ReplayEntry]()
        var baseDate: Date?
        var lastOffset: TimeInterval = 0

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }

            if line.hasPrefix("+") {
                // 簡易形式。先頭が "+" なら必ずこの形式として扱い、壊れていればエラーにする。
                entries.append(try parseSimpleLine(line, number: lineNumber))
            } else if line.hasPrefix("[") {
                // sniffer ログ。パケット行でなければ黙って読み飛ばす。
                guard let packet = try parseSnifferLine(line, number: lineNumber) else { continue }
                let offset: TimeInterval
                if let date = packet.date {
                    if let base = baseDate {
                        offset = date.timeIntervalSince(base)
                    } else {
                        baseDate = date
                        offset = 0
                    }
                } else {
                    offset = entries.isEmpty ? 0 : lastOffset + (packet.deltaSeconds ?? 0)
                }
                lastOffset = offset
                entries.append(
                    ReplayEntry(
                        offsetSeconds: max(0, offset),
                        characteristic: packet.characteristic,
                        data: packet.data
                    )
                )
            }
            // それ以外の行は sniffer ログの雑多な出力とみなして無視する。
        }

        return ReplayScript(entries: entries)
    }

    /// スクリプトをテキスト（簡易形式）に書き出す。
    public func serialized() -> String {
        entries.map { entry in
            let ms = Int((entry.offsetSeconds * 1000).rounded())
            return "+\(ms) \(BluetoothUUID.displayString(entry.characteristic)) \(HexBytes.string(entry.data))"
        }
        .joined(separator: "\n")
    }

    // MARK: - 行パーサ

    private static func parseSimpleLine(_ line: String, number: Int) throws -> ReplayEntry {
        // "+<ms> <uuid> <hex...>"
        let body = line.dropFirst()
        let fields = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let milliseconds = Double(fields[0]) else {
            throw ReplayScriptError.malformedLine(number: number, text: line)
        }
        guard let uuid = BluetoothUUID.parse(String(fields[1])) else {
            throw ReplayScriptError.badUUID(number: number, text: String(fields[1]))
        }
        // hex の後ろにコメントが付いていても落とせるようにする。
        let hexText = String(fields[2]).components(separatedBy: "#")[0]
        guard let data = HexBytes.parse(hexText) else {
            throw ReplayScriptError.badHex(number: number, text: hexText)
        }
        return ReplayEntry(offsetSeconds: milliseconds / 1000.0, characteristic: uuid, data: data)
    }

    private struct SnifferPacket {
        let date: Date?
        let deltaSeconds: TimeInterval?
        let characteristic: UUID
        let data: Data
    }

    /// sniffer ログのパケット行を解釈する。パケット行でなければ `nil`。
    private static func parseSnifferLine(_ line: String, number: Int) throws -> SnifferPacket? {
        // [<ts>] [+<delta> ms] <UUID> len=<n> hex: <bytes> [ascii: ...]
        guard let firstClose = line.firstIndex(of: "]") else { return nil }
        let timestampText = String(line[line.index(after: line.startIndex)..<firstClose])

        var rest = line[line.index(after: firstClose)...].trimmingCharacters(in: .whitespaces)
        // 2 つ目のブラケットが "+... ms" でなければパケット行ではない（write 行など）。
        guard rest.hasPrefix("["), let secondClose = rest.firstIndex(of: "]") else { return nil }
        let deltaText = String(rest[rest.index(after: rest.startIndex)..<secondClose])
        guard deltaText.hasPrefix("+"), deltaText.hasSuffix("ms") else { return nil }

        rest = String(rest[rest.index(after: secondClose)...]).trimmingCharacters(in: .whitespaces)
        guard let hexRange = rest.range(of: "hex:") else { return nil }

        let head = rest[rest.startIndex..<hexRange.lowerBound]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let uuidField = head.first else { return nil }
        guard let uuid = BluetoothUUID.parse(String(uuidField)) else {
            throw ReplayScriptError.badUUID(number: number, text: String(uuidField))
        }

        var hexText = String(rest[hexRange.upperBound...])
        if let asciiRange = hexText.range(of: "ascii:") {
            hexText = String(hexText[hexText.startIndex..<asciiRange.lowerBound])
        }
        hexText = hexText.trimmingCharacters(in: .whitespaces)
        // len=0 のパケットもあり得るので、空 hex は空データとして通す。
        let data: Data
        if hexText.isEmpty {
            data = Data()
        } else if let parsed = HexBytes.parse(hexText) {
            data = parsed
        } else {
            throw ReplayScriptError.badHex(number: number, text: hexText)
        }

        let deltaValue = deltaText
            .dropFirst()               // "+"
            .dropLast(2)               // "ms"
            .trimmingCharacters(in: .whitespaces)
        let delta = Double(deltaValue).map { $0 / 1000.0 }   // "----" は nil になる

        return SnifferPacket(
            date: snifferDateFormatter.date(from: timestampText),
            deltaSeconds: delta,
            characteristic: uuid,
            data: data
        )
    }

    /// `Sources/ShotLogSniff/Commands.swift` の `Timestamp.iso8601` と同じ書式。
    ///
    private static let snifferDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return formatter
    }()
}
