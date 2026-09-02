import Foundation

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
    /// 使い方を表示する。
    case help
    /// `target` が nil なら既定の write characteristic へ送る。
    case write(target: String?, payload: Data)
    case read(target: String)
    case setNotify(target: String, enabled: Bool)
    /// 解釈できなかった入力。`message` は理由。
    case invalid(message: String)

    /// 未知の入力に対して 1 行で出す使い方。
    static let usage =
        "usage: <hex> | w <char> <hex> | r <char> | sub <char> | unsub <char> | list | q"

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
        case "h", "help", "?":
            return .help
        case "w", "write":
            guard rest.count >= 2 else {
                return .invalid(message: "w は <charUUID|prefix> <hex> の 2 引数が必要です")
            }
            let hexText = rest.dropFirst().joined()
            guard let payload = Hex.parse(hexText) else {
                return .invalid(message: "hex が不正です（偶数桁の 16 進数で指定）: \(hexText)")
            }
            return .write(target: rest[0], payload: payload)
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
                return .write(target: nil, payload: payload)
            }
            return .invalid(message: "解釈できません: \(line)")
        }
    }

    /// 対話モード開始時に出すヘルプ。
    static let helpText = """
        --- interactive mode ---
          <hex>                 既定の write characteristic へ送る  (例: 5a 4b 00 4b / 5a4b004b)
          w <char> <hex>        characteristic を指定して write
          r <char>              characteristic を read
          sub <char>            notify を購読
          unsub <char>          notify を解除
          list                  GATT ツリーを再表示
          h                     このヘルプ
          q / Ctrl-D            切断して終了
        <char> は characteristic UUID か、一意に決まる前置一致（例: ffe1）。
        # で始まる行と空行は無視されます。
        """
}
