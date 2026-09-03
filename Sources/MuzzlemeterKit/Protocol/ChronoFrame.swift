import Foundation

/// The AC6000 MKIII BT's application-layer frame.
///
/// `docs/PROTOCOL.md` §3 (identical for TX/RX; confirmed against 23 captured frames):
/// ```
/// offset 0      : header = 0xAA
/// offset 1      : L      = total frame length (header/len/cmd/payload/checksum combined)
/// offset 2      : cmd
/// offset 3..L-2 : payload
/// offset L-1    : checksum = (sum(frame[0..L-2]) + key1 + key2) & 0xFF
/// ```
/// So `L == payload.count + 4` (payload doesn't include cmd).
public struct ChronoFrame: Sendable, Hashable {
    /// The frame header. Confirmed value is 0xAA.
    public static let header: UInt8 = 0xAA
    /// The frame length when payload is 0 bytes: header + L + cmd + checksum.
    public static let minimumLength = 4
    /// L is 1 byte, so a frame is at most 255 bytes.
    public static let maximumLength = 255

    public let cmd: UInt8
    public let payload: [UInt8]

    public init(cmd: UInt8, payload: [UInt8] = []) {
        self.cmd = cmd
        self.payload = payload
    }

    public init(command: ChronoCommand, payload: [UInt8] = []) {
        self.init(cmd: command.rawValue, payload: payload)
    }

    /// The total frame length = the value that goes in the `L` field.
    public var length: Int { payload.count + Self.minimumLength }

    /// The enum case for a known opcode. `nil` if unknown.
    public var command: ChronoCommand? { ChronoCommand(rawValue: cmd) }

    // MARK: - Checksum

    /// `(sum(bytes) + key1 + key2) & 0xFF`.
    ///
    /// A client that doesn't know the key can neither build a frame nor verify one.
    /// This is what the AC6000's "pairing" actually amounts to (there's no link-layer
    /// encryption or bonding at all).
    public static func checksum<Bytes: Sequence<UInt8>>(_ bytes: Bytes, keys: DeviceKeys) -> UInt8 {
        var sum = keys.sum
        for byte in bytes { sum &+= Int(byte) }
        return UInt8(sum & 0xFF)
    }

    // MARK: - Encoding

    /// Signs with the key and produces the bytes to transmit.
    ///
    /// Only `0x4B` (READ_KEY) is sent **before** the key is established, so encode it
    /// with `keys: .zero`. `ChronoRequest.encoded(keys:)` handles that special case.
    public func encode(keys: DeviceKeys) -> Data {
        precondition(length <= Self.maximumLength, "Frame too long: \(length) bytes")
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        bytes.append(Self.header)
        bytes.append(UInt8(length))
        bytes.append(cmd)
        bytes.append(contentsOf: payload)
        bytes.append(Self.checksum(bytes, keys: keys))
        return Data(bytes)
    }

    // MARK: - Decoding

    /// Validates one byte sequence and turns it into a frame.
    ///
    /// - Parameters:
    ///   - keys: the key used for validation.
    ///   - acceptUnkeyedChecksum: also accept a checksum that matches the unkeyed (0/0)
    ///     sum. Enabled by default for the `0x4B` response during first-time pairing
    ///     (key unknown), and for debugging a mismatched key. Set to `false` to perform
    ///     only the strict validation described in `docs/PROTOCOL.md` §3.1.
    public static func decode(
        _ data: Data,
        keys: DeviceKeys,
        acceptUnkeyedChecksum: Bool = true
    ) -> Result<ChronoFrame, ChronoFrameError> {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return .failure(.empty) }
        guard bytes[0] == header else { return .failure(.badHeader(bytes[0])) }
        guard bytes.count >= minimumLength else { return .failure(.tooShort(bytes.count)) }

        let declared = Int(bytes[1])
        guard declared >= minimumLength else { return .failure(.badLengthField(bytes[1])) }
        guard declared == bytes.count else {
            return .failure(.lengthMismatch(declared: declared, actual: bytes.count))
        }

        let body = bytes[0..<(bytes.count - 1)]
        let actual = bytes[bytes.count - 1]
        let expected = checksum(body, keys: keys)
        if actual != expected {
            let unkeyed = checksum(body, keys: .zero)
            guard acceptUnkeyedChecksum, actual == unkeyed else {
                return .failure(.checksumMismatch(expected: expected, actual: actual))
            }
        }

        return .success(
            ChronoFrame(cmd: bytes[2], payload: Array(bytes[3..<(bytes.count - 1)]))
        )
    }
}

/// Why frame validation failed.
public enum ChronoFrameError: Error, Sendable, Hashable, CustomStringConvertible {
    case empty
    case badHeader(UInt8)
    case tooShort(Int)
    /// The L field is smaller than the minimum frame length.
    case badLengthField(UInt8)
    case lengthMismatch(declared: Int, actual: Int)
    case checksumMismatch(expected: UInt8, actual: UInt8)

    public var description: String {
        switch self {
        case .empty:
            "空のフレーム"
        case .badHeader(let value):
            String(format: "ヘッダが 0xAA ではありません: 0x%02x", value)
        case .tooShort(let count):
            "フレームが短すぎます: \(count) bytes（最小 \(ChronoFrame.minimumLength)）"
        case .badLengthField(let value):
            String(format: "長さフィールドが不正です: 0x%02x", value)
        case .lengthMismatch(let declared, let actual):
            "長さが一致しません: L=\(declared) 実際=\(actual)"
        case .checksumMismatch(let expected, let actual):
            String(format: "チェックサム不一致: 期待 0x%02x 実際 0x%02x", expected, actual)
        }
    }
}

/// Slices bytes arriving over notify into frames.
///
/// The measured MTU is 247 and a frame is at most 11 bytes, so normally 1 notification =
/// 1 frame, but **this must not be implemented as if it depended on the MTU**
/// (`docs/PROTOCOL.md` §2.1). Because of that, this is built to tolerate:
/// * arriving split (only the first half showed up)
/// * arriving concatenated (two frames arrived together)
/// * garbage bytes stuck on the front
/// Slicing is driven **only by the L field**.
public struct FrameAssembler: Sendable {
    /// The result of slicing.
    public enum Output: Sendable, Hashable {
        /// A frame that passed validation.
        case frame(ChronoFrame, raw: Data)
        /// A 1-byte `00` notification = **the device's power-off signature**
        /// (`docs/PROTOCOL.md` §5.1). Not an error. The link drops via supervision
        /// timeout about 0.76 s later.
        case powerOff
        /// The header/length could be read but the checksum didn't match, or bytes were
        /// skipped after losing sync. Passed up rather than discarded, so it can still be
        /// logged.
        case invalid(raw: Data, error: ChronoFrameError)
    }

    /// The buffer size limit. Past this, sync is assumed to be broken and the buffer is
    /// discarded. Normally only about 11 bytes accumulate.
    public static let bufferLimit = 1024

    private var buffer = [UInt8]()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    /// Feeds in the bytes from one notify and returns whatever could be sliced out.
    public mutating func append(_ data: Data) -> [Output] {
        // A single 0x00 byte isn't a "frame," so check for it before it's added to the
        // buffer. If an incomplete frame is already sitting in the buffer, this byte
        // could be part of it, so that case falls through to the normal path instead.
        if buffer.isEmpty, data.count == 1, data.first == 0x00 {
            return [.powerOff]
        }

        buffer.append(contentsOf: data)
        var results = [Output]()

        while !buffer.isEmpty {
            // 1) Resync: discard bytes until the first one is 0xAA.
            if buffer[0] != ChronoFrame.header {
                guard let headerIndex = buffer.firstIndex(of: ChronoFrame.header) else {
                    results.append(
                        .invalid(raw: Data(buffer), error: .badHeader(buffer[0]))
                    )
                    buffer.removeAll(keepingCapacity: true)
                    break
                }
                let dropped = Array(buffer[0..<headerIndex])
                results.append(.invalid(raw: Data(dropped), error: .badHeader(dropped[0])))
                buffer.removeFirst(headerIndex)
                continue
            }

            // 2) Wait until the L field has arrived.
            guard buffer.count >= 2 else { break }
            let declared = Int(buffer[1])
            guard declared >= ChronoFrame.minimumLength else {
                // Not a plausible length. Treat it as a false-positive header match and
                // advance by 1 byte.
                results.append(.invalid(raw: Data(buffer.prefix(2)), error: .badLengthField(buffer[1])))
                buffer.removeFirst(1)
                continue
            }

            // 3) Wait until the whole frame has arrived.
            guard buffer.count >= declared else { break }

            let raw = Data(buffer[0..<declared])
            buffer.removeFirst(declared)
            switch ChronoFrame.decode(raw, keys: keys, acceptUnkeyedChecksum: acceptsUnkeyedChecksum) {
            case .success(let frame):
                results.append(.frame(frame, raw: raw))
            case .failure(let error):
                results.append(.invalid(raw: raw, error: error))
            }
        }

        if buffer.count > Self.bufferLimit {
            results.append(.invalid(raw: Data(buffer), error: .tooShort(buffer.count)))
            buffer.removeAll(keepingCapacity: true)
        }

        return results
    }

    // MARK: - Validation settings

    /// The key used for checksum validation. Swap it in once the handshake confirms it.
    public var keys: DeviceKeys = .zero
    /// Whether to also accept a match against the unkeyed sum (same meaning as in
    /// `ChronoFrame.decode`).
    public var acceptsUnkeyedChecksum = true
}
