import Foundation

/// Whether a write is sent as withResponse or withoutResponse.
///
/// Some implementations on the other end only process write-without-response, while
/// others require withResponse, so this needs to be switchable explicitly while
/// reverse-engineering.
enum WriteTypePreference: String, CaseIterable, Sendable {
    /// Decide from the characteristic's properties (withResponse if `write` is present).
    case auto
    /// Always withResponse.
    case with
    /// Always withoutResponse.
    case without
}

/// The result of interpreting one line of input read from stdin during
/// `dump --interactive`.
///
/// A pure parser that never touches BLE at all, so it's meaningful even in an
/// environment without CoreBluetooth.
enum InteractiveCommand: Equatable, Sendable {
    /// A blank line or comment line. Does nothing.
    case none
    /// Disconnect and quit.
    case quit
    /// Redisplay the GATT tree.
    case list
    /// Show the maximum number of bytes that can be sent in one write.
    case mtu
    /// Show usage.
    case help
    /// Sent to the default write characteristic when `target` is nil.
    /// Follows the `--write-type` setting when `type` is nil.
    case write(target: String?, payload: Data, type: WriteTypePreference?)
    case read(target: String)
    case setNotify(target: String, enabled: Bool)
    /// Input that couldn't be parsed. `message` is why.
    case invalid(message: String)

    /// The one-line usage shown for unrecognized input.
    static let usage =
        "usage: <hex> | w <char> <hex> | wr|wn [<char>] <hex> | r <char> | sub <char> | unsub <char> | mtu | list | q"

    /// Splits one line on `;` and interprets it as multiple commands.
    ///
    /// Lets multiple frames be sent from a single line, like
    /// `85 06 4b 00 00 d6 ; 85 05 5a 00 e4`. If even one of them can't be parsed,
    /// **nothing is executed** (to avoid sending only the first half on a typo), so just
    /// that `.invalid` is returned.
    static func parseLine(_ rawLine: String) -> [InteractiveCommand] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { return [] }

        var result = [InteractiveCommand]()
        for segment in line.split(separator: ";", omittingEmptySubsequences: false) {
            let command = parse(String(segment))
            switch command {
            case .none: continue
            case .invalid: return [command]
            default: result.append(command)
            }
        }
        return result
    }

    static func parse(_ rawLine: String) -> InteractiveCommand {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { return .none }

        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let head = parts.first else { return .none }
        let rest = Array(parts.dropFirst())

        switch head.lowercased() {
        case "q", "quit", "exit":
            return .quit
        case "list", "ls", "gatt":
            return .list
        case "mtu":
            return .mtu
        case "h", "help", "?":
            return .help
        case "w", "write":
            // The original form. The characteristic is always explicit; the write type
            // follows --write-type.
            guard rest.count >= 2 else {
                return .invalid(message: "w は <charUUID|prefix> <hex> の 2 引数が必要です")
            }
            return makeWrite(target: rest[0], hexTokens: Array(rest.dropFirst()), type: nil)
        case "wr":
            return parseTypedWrite(rest, type: .with, name: "wr")
        case "wn":
            return parseTypedWrite(rest, type: .without, name: "wn")
        case "r", "read":
            guard rest.count == 1 else {
                return .invalid(message: "r は <charUUID|prefix> の 1 引数が必要です")
            }
            return .read(target: rest[0])
        case "sub", "subscribe":
            guard rest.count == 1 else {
                return .invalid(message: "sub は <charUUID|prefix> の 1 引数が必要です")
            }
            return .setNotify(target: rest[0], enabled: true)
        case "unsub", "unsubscribe":
            guard rest.count == 1 else {
                return .invalid(message: "unsub は <charUUID|prefix> の 1 引数が必要です")
            }
            return .setNotify(target: rest[0], enabled: false)
        default:
            // If it isn't a command word, treat it as hex bound for the default
            // characteristic.
            if let payload = Hex.parse(parts.joined()) {
                return .write(target: nil, payload: payload, type: nil)
            }
            return .invalid(message: "解釈できません: \(line)")
        }
    }

    /// `wr` / `wn` accept both `<hex>` and `<char> <hex>`.
    ///
    /// Only treated as a characteristic when the first token has a UUID-like shape
    /// (4 / 8 / 36 digits) and more tokens follow it. In `wn 85 06 4b`, `85` is only 2
    /// digits, so it stays hex. To send 4-digit-grouped hex to the default
    /// characteristic, join it into a single token with no spaces.
    private static func parseTypedWrite(
        _ rest: [String],
        type: WriteTypePreference,
        name: String
    ) -> InteractiveCommand {
        guard let first = rest.first else {
            return .invalid(message: "\(name) は <hex> または <charUUID|prefix> <hex> が必要です")
        }
        if rest.count >= 2, looksLikeCharacteristicToken(first) {
            return makeWrite(target: first, hexTokens: Array(rest.dropFirst()), type: type)
        }
        return makeWrite(target: nil, hexTokens: rest, type: type)
    }

    private static func makeWrite(
        target: String?,
        hexTokens: [String],
        type: WriteTypePreference?
    ) -> InteractiveCommand {
        let hexText = hexTokens.joined()
        guard let payload = Hex.parse(hexText) else {
            return .invalid(message: "hex が不正です（偶数桁の 16 進数で指定）: \(hexText)")
        }
        return .write(target: target, payload: payload, type: type)
    }

    /// Judges only "does this look like a UUID," without touching CoreBluetooth.
    private static func looksLikeCharacteristicToken(_ token: String) -> Bool {
        switch token.count {
        case 4, 8:
            return token.allSatisfy(\.isHexDigit)
        case 36:
            return UUID(uuidString: token) != nil
        default:
            return false
        }
    }

    /// The help shown when interactive mode starts.
    static let helpText = """
        --- interactive mode ---
          <hex>                 既定の write characteristic へ送る  (例: 5a 4b 00 4b / 5a4b004b)
          w <char> <hex>        characteristic を指定して write（種別は --write-type に従う）
          wr [<char>] <hex>     withResponse で write
          wn [<char>] <hex>     withoutResponse で write
          r <char>              characteristic を read
          sub <char>            notify を購読
          unsub <char>          notify を解除
          mtu                   1 回の write で送れる最大バイト数を表示
          list                  GATT ツリーを再表示
          h                     このヘルプ
          q / Ctrl-D            切断して終了
        1 行に ";" 区切りで複数フレームを書くと --write-delay 間隔で順に送ります。
          例: 85 06 4b 00 00 d6 ; 85 05 5a 00 e4
        <char> は characteristic UUID か、一意に決まる前置一致（例: ffe1）。
        wr / wn はトークンが 2 つ以上あり先頭が 4/8/36 桁のときだけ characteristic 指定と解釈します
        （4 桁区切りの hex を既定の宛先へ送るときは "wn 85064b00" のように空白を詰めてください）。
        # で始まる行と空行は無視されます。
        """
}
