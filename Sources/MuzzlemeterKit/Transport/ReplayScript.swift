import Foundation

/// One line of a replay script = one packet that arrived at a given time.
public struct ReplayEntry: Sendable, Hashable {
    /// Seconds elapsed from the start of the script.
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

/// A recorded packet sequence. `ReplayTransport` plays it back along its own timeline.
///
/// Two text formats can be read.
///
/// **1. A simple hand-written format** — lines starting with `+`:
/// ```
/// +0     FFE1  a0 23 00 00
/// +1500  FFE1  b4 23 00 00
/// ```
/// `+<milliseconds>` is the **absolute offset from the start of the script**. Lines
/// starting with `#` and blank lines are ignored.
///
/// **2. The `muzzlemeter-sniff dump` log format** — readable as-is:
/// ```
/// [2026-09-02T22:31:04.512+09:00] [+412.7 ms] FFE1 len=8 hex: aa 55 01 5a ascii: .U.Z
/// ```
/// The offset is the difference between ISO8601 timestamps (the first packet line is
/// treated as 0). For a line whose timestamp can't be read, the `[+N ms]` delta is
/// accumulated instead. Non-packet lines (the GATT tree, `write ->`, `read `, and other
/// log lines) are skipped.
public struct ReplayScript: Sendable, Hashable {
    public var entries: [ReplayEntry]

    public init(entries: [ReplayEntry]) {
        self.entries = entries.sorted { $0.offsetSeconds < $1.offsetSeconds }
    }

    public var duration: TimeInterval { entries.last?.offsetSeconds ?? 0 }

    /// The characteristics that appear in the script (deduplicated, in order of
    /// appearance).
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
                // The simple format. If a line starts with "+" it's always treated as
                // this format, and an error is raised if it's malformed.
                entries.append(try parseSimpleLine(line, number: lineNumber))
            } else if line.hasPrefix("[") {
                // A sniffer log line. Silently skipped if it isn't a packet line.
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
            // Any other line is treated as miscellaneous sniffer log output and ignored.
        }

        return ReplayScript(entries: entries)
    }

    /// Serializes the script back to text (the simple format).
    public func serialized() -> String {
        entries.map { entry in
            let ms = Int((entry.offsetSeconds * 1000).rounded())
            return "+\(ms) \(BluetoothUUID.displayString(entry.characteristic)) \(HexBytes.string(entry.data))"
        }
        .joined(separator: "\n")
    }

    // MARK: - Line parsers

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
        // Allow a trailing comment after the hex to be dropped.
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

    /// Parses a sniffer log's packet line. `nil` if it isn't a packet line.
    private static func parseSnifferLine(_ line: String, number: Int) throws -> SnifferPacket? {
        // [<ts>] [+<delta> ms] <UUID> len=<n> hex: <bytes> [ascii: ...]
        guard let firstClose = line.firstIndex(of: "]") else { return nil }
        let timestampText = String(line[line.index(after: line.startIndex)..<firstClose])

        var rest = line[line.index(after: firstClose)...].trimmingCharacters(in: .whitespaces)
        // Not a packet line (e.g. a write line) if the second bracket isn't "+... ms".
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
        // A len=0 packet is possible, so empty hex is treated as empty data.
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
        let delta = Double(deltaValue).map { $0 / 1000.0 }   // "----" becomes nil

        return SnifferPacket(
            date: snifferDateFormatter.date(from: timestampText),
            deltaSeconds: delta,
            characteristic: uuid,
            data: data
        )
    }

    /// The same format as `Timestamp.iso8601` in `Sources/MuzzlemeterSniff/Commands.swift`.
    private static let snifferDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return formatter
    }()
}
