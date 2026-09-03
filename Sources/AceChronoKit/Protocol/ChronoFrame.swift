import Foundation

/// AC6000 MKIII BT のアプリケーション層フレーム。
///
/// `docs/PROTOCOL.md` §3（TX / RX 完全に同一・実測 23 フレームで検証済み）:
/// ```
/// offset 0      : header = 0xAA
/// offset 1      : L      = フレーム全長（header/len/cmd/payload/checksum の合計）
/// offset 2      : cmd
/// offset 3..L-2 : payload
/// offset L-1    : checksum = (Σ frame[0..L-2] + key1 + key2) & 0xFF
/// ```
/// したがって `L == payload.count + 4`（payload は cmd を含まない）。
public struct ChronoFrame: Sendable, Hashable {
    /// フレームヘッダ。実測値は 0xAA。
    public static let header: UInt8 = 0xAA
    /// payload 0 バイトのときのフレーム長。header + L + cmd + checksum。
    public static let minimumLength = 4
    /// L は 1 バイトなので、フレームは最大 255 バイト。
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

    /// フレーム全長 = `L` フィールドに入る値。
    public var length: Int { payload.count + Self.minimumLength }

    /// 既知の opcode ならその enum。未知なら `nil`。
    public var command: ChronoCommand? { ChronoCommand(rawValue: cmd) }

    // MARK: - チェックサム

    /// `(Σ bytes + key1 + key2) & 0xFF`。
    ///
    /// 鍵を知らないクライアントはフレームを組めないし検証もできない。
    /// これが AC6000 の「ペアリング」の実体（リンク層の暗号化・ボンディングは一切無い）。
    public static func checksum<Bytes: Sequence<UInt8>>(_ bytes: Bytes, keys: DeviceKeys) -> UInt8 {
        var sum = keys.sum
        for byte in bytes { sum &+= Int(byte) }
        return UInt8(sum & 0xFF)
    }

    // MARK: - エンコード

    /// 鍵で署名して送信バイト列にする。
    ///
    /// `0x4B`（READ_KEY）だけは鍵確立**前**に送るため `keys: .zero` で符号化すること。
    /// `ChronoRequest.encoded(keys:)` がその特例を持っている。
    public func encode(keys: DeviceKeys) -> Data {
        precondition(length <= Self.maximumLength, "フレームが長すぎます: \(length) bytes")
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        bytes.append(Self.header)
        bytes.append(UInt8(length))
        bytes.append(cmd)
        bytes.append(contentsOf: payload)
        bytes.append(Self.checksum(bytes, keys: keys))
        return Data(bytes)
    }

    // MARK: - デコード

    /// バイト列 1 本を検証してフレームにする。
    ///
    /// - Parameters:
    ///   - keys: 検証に使う鍵。
    ///   - acceptUnkeyedChecksum: 鍵なし（0/0）の総和とも一致すれば通す。
    ///     初回ペアリング（鍵未知）の `0x4B` 応答や、鍵を取り違えたときの
    ///     デバッグのために既定で有効。`docs/PROTOCOL.md` §3.1 の厳密検証だけを
    ///     行いたい場合は `false` にする。
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

/// フレーム検証の失敗理由。
public enum ChronoFrameError: Error, Sendable, Hashable, CustomStringConvertible {
    case empty
    case badHeader(UInt8)
    case tooShort(Int)
    /// L フィールドが最小フレーム長より小さい。
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

/// notify で届いたバイト列をフレームに切り出す。
///
/// 実測 MTU は 247 で、フレームは最大 11 バイトなので通常は 1 通知 = 1 フレームだが、
/// **MTU に依存する実装にしないこと**（`docs/PROTOCOL.md` §2.1）。そのためここでは
/// * 分割されて届いた（前半だけ来た）
/// * 連結されて届いた（2 本まとめて来た）
/// * 先頭にごみが乗った
/// のいずれにも耐えるようにしてある。切り出しは **L フィールド**だけで行う。
public struct FrameAssembler: Sendable {
    /// 切り出しの結果。
    public enum Output: Sendable, Hashable {
        /// 検証を通ったフレーム。
        case frame(ChronoFrame, raw: Data)
        /// 1 バイトの `00` 通知 = **本体の電源 OFF シグネチャ**（`docs/PROTOCOL.md` §5.1）。
        /// エラーではない。0.76 秒後にリンクが supervision timeout で落ちる。
        case powerOff
        /// ヘッダ/長さは取れたがチェックサムが合わなかった、あるいは同期が外れて
        /// 読み飛ばしたバイト列。捨てずに上位へ渡してログできるようにする。
        case invalid(raw: Data, error: ChronoFrameError)
    }

    /// バッファ上限。これを超えたら同期が壊れているとみなして捨てる。
    /// 正常時は 11 バイト程度しか溜まらない。
    public static let bufferLimit = 1024

    private var buffer = [UInt8]()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    /// 1 回の notify で届いたバイト列を投入し、切り出せたものを返す。
    public mutating func append(_ data: Data) -> [Output] {
        // 1 バイトの 00 は「フレーム」ではないので、バッファに入れる前に判定する。
        // バッファに未完成のフレームが残っているときは、その途中バイトの可能性を
        // 否定できないため通常経路へ流す。
        if buffer.isEmpty, data.count == 1, data.first == 0x00 {
            return [.powerOff]
        }

        buffer.append(contentsOf: data)
        var results = [Output]()

        while !buffer.isEmpty {
            // 1) 同期を取る: 先頭が 0xAA になるまで捨てる。
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

            // 2) L フィールドが来るまで待つ。
            guard buffer.count >= 2 else { break }
            let declared = Int(buffer[1])
            guard declared >= ChronoFrame.minimumLength else {
                // 長さとしてあり得ない。ヘッダの誤検出とみなして 1 バイト進める。
                results.append(.invalid(raw: Data(buffer.prefix(2)), error: .badLengthField(buffer[1])))
                buffer.removeFirst(1)
                continue
            }

            // 3) フレーム全体が揃うまで待つ。
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

    // MARK: - 検証設定

    /// チェックサム検証に使う鍵。ハンドシェイクで確定したら差し替える。
    public var keys: DeviceKeys = .zero
    /// 鍵なしの総和とも一致すれば通すか（`ChronoFrame.decode` と同じ意味）。
    public var acceptsUnkeyedChecksum = true
}
