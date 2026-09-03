import Foundation

/// write を withResponse / withoutResponse のどちらで送るかの指定。
///
/// 相手が write without response しか処理しない実装だったり、逆に withResponse を
/// 要求したりすることがあるため、解析中は明示的に切り替えられる必要がある。
enum WriteTypePreference: String, CaseIterable, Sendable {
    /// characteristic のプロパティから決める（write があれば withResponse）。
    case auto
    /// 常に withResponse。
    case with
    /// 常に withoutResponse。
    case without
}

/// `dump --interactive` で stdin から 1 行ずつ読んだ入力を解釈した結果。
///
/// BLE には一切触らない純粋なパーサなので、CoreBluetooth を持たない環境でも意味を持つ。
enum InteractiveCommand: Equatable, Sendable {
    /// 空行・コメント行。何もしない。
    case none
    /// 切断して終了する。
    case quit
    /// GATT ツリーを再表示する。
    case list
    /// 1 回の write で送れる最大バイト数を表示する。
    case mtu
    /// 使い方を表示する。
    case help
    /// `target` が nil なら既定の write characteristic へ送る。
    /// `type` が nil なら `--write-type` の指定に従う。
    case write(target: String?, payload: Data, type: WriteTypePreference?)
    case read(target: String)
    case setNotify(target: String, enabled: Bool)
    /// 解釈できなかった入力。`message` は理由。
    case invalid(message: String)

    /// 未知の入力に対して 1 行で出す使い方。
    static let usage =
        "usage: <hex> | w <char> <hex> | wr|wn [<char>] <hex> | r <char> | sub <char> | unsub <char> | mtu | list | q"

    /// 1 行を `;` で区切って複数コマンドとして解釈する。
    ///
    /// `85 06 4b 00 00 d6 ; 85 05 5a 00 e4` のように 1 行で複数フレームを送れるようにするため。
    /// どれか 1 つでも解釈できなければ**何も実行しない**（打ち間違いで前半だけ送るのを防ぐ）ので、
    /// その `.invalid` だけを返す。
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
            // 既存の形。characteristic は常に明示する。write type は --write-type に従う。
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
            // コマンド語でなければ既定 characteristic 宛ての hex とみなす。
            if let payload = Hex.parse(parts.joined()) {
                return .write(target: nil, payload: payload, type: nil)
            }
            return .invalid(message: "解釈できません: \(line)")
        }
    }

    /// `wr` / `wn` は `<hex>` と `<char> <hex>` の両方を取る。
    ///
    /// 先頭トークンが UUID の形（4 / 8 / 36 桁）で、かつ後ろにトークンが続く場合だけ
    /// characteristic 指定とみなす。`wn 85 06 4b` の `85` は 2 桁なので hex のまま。
    /// 4 桁区切りの hex を既定 characteristic へ送りたいときは空白を詰めて 1 トークンにする。
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

    /// CoreBluetooth に触らずに「UUID っぽいか」だけを判定する。
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

    /// 対話モード開始時に出すヘルプ。
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
