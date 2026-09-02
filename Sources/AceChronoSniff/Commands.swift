import ArgumentParser
import CoreBluetooth
import Foundation

/// `dispatchMain()` の後もインスタンスを生かしておくための保持箱。
enum SnifferHolder {
    nonisolated(unsafe) static var current: BLESniffer?
}

struct SniffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acechrono-sniff",
        abstract: "Acetech AC6000 MKIII BT の BLE プロトコル解析用ダンプツール",
        discussion: """
            macOS の CoreBluetooth を使って BLE デバイスをスキャン・接続し、
            GATT の構造と notify されてくるパケットを hex でダンプします。

            初回実行時は macOS が Bluetooth の使用許可を求めます。許可されない場合は
            システム設定 > プライバシーとセキュリティ > Bluetooth で
            Terminal.app / iTerm.app を有効にしてください。
            """,
        subcommands: [Scan.self, Dump.self],
        defaultSubcommand: Scan.self
    )
}

// MARK: - scan

extension SniffCommand {
    struct Scan: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scan",
            abstract: "周囲の BLE アドバタイズを一覧表示する"
        )

        @Option(name: .long, help: "スキャン時間（秒）")
        var seconds: Double = 10

        @Option(name: .customLong("filter-service"), help: "このサービス UUID を持つデバイスのみスキャンする")
        var filterService: String?

        func run() throws {
            let filter = try parseServiceFilter(filterService)
            let sniffer = BLESniffer(
                mode: .scan(seconds: seconds),
                serviceFilter: filter,
                logger: LogWriter(path: nil)
            )
            SnifferHolder.current = sniffer
            sniffer.start()
            dispatchMain()
        }
    }
}

// MARK: - dump

extension SniffCommand {
    struct Dump: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dump",
            abstract: "デバイスに接続し GATT を列挙して notify を全購読・ダンプする",
            discussion: """
                例:
                  acechrono-sniff dump --name AC6000
                  acechrono-sniff dump --id 1234ABCD-... --log tools/re/captures/shot1.log
                  acechrono-sniff dump --name AC6000 --write ffe1 01a50000 --write ffe1 02
                  acechrono-sniff dump --name AC6000 --interactive

                --interactive では購読完了後に stdin からコマンドを受け付けます:
                  <hex>            既定の write characteristic へ送る (例: 5a 4b 00 4b)
                  w <char> <hex>   characteristic を指定して write
                  r <char>         read
                  sub / unsub <char>  notify の購読 / 解除
                  list             GATT ツリー再表示
                  q / Ctrl-D       切断して終了
                """
        )

        @Option(name: .long, help: "デバイス名に含まれる文字列（部分一致・大文字小文字を無視）")
        var name: String?

        @Option(name: .customLong("id"), help: "CoreBluetooth の peripheral identifier (UUID)")
        var id: String?

        @Option(name: .long, help: "ログ出力先。既定は tools/re/captures/<yyyyMMdd-HHmmss>.log")
        var log: String?

        @Option(name: .customLong("filter-service"), help: "このサービス UUID を持つデバイスのみスキャンする")
        var filterService: String?

        @Option(
            name: .customLong("write"),
            parsing: .upToNextOption,
            help: ArgumentHelp(
                "購読後に送信するコマンド。<charUUID> <hex> の 2 値を指定し、複数回指定可能。",
                valueName: "charUUID hex"
            )
        )
        var write: [String] = []

        @Option(
            name: .customLong("write-delay"),
            help: ArgumentHelp(
                "連続する --write の間隔（ミリ秒）。応答をどの write のものか対応付けるため。",
                valueName: "ms"
            )
        )
        var writeDelay: Int = 200

        @Flag(
            name: [.short, .long],
            help: "購読・--write 完了後に stdin からコマンドを受け付ける対話モード。"
        )
        var interactive: Bool = false

        func validate() throws {
            guard (name == nil) != (id == nil) else {
                throw ValidationError("--name か --id のどちらか一方を指定してください。")
            }
            guard writeDelay >= 0 else {
                throw ValidationError("--write-delay は 0 以上で指定してください: \(writeDelay)")
            }
            _ = try parseWrites(write)
            _ = try parseServiceFilter(filterService)
        }

        func run() throws {
            let matcher: PeripheralMatcher
            if let name {
                matcher = .name(name)
            } else if let id {
                guard UUID(uuidString: id) != nil else {
                    throw ValidationError("--id は UUID 形式で指定してください: \(id)")
                }
                matcher = .identifier(id)
            } else {
                throw ValidationError("--name か --id を指定してください。")
            }

            let writes = try parseWrites(write)
            let filter = try parseServiceFilter(filterService)
            let logPath = log ?? "tools/re/captures/\(Timestamp.fileStamp(Date())).log"

            let sniffer = BLESniffer(
                mode: .dump(
                    matcher: matcher,
                    writes: writes,
                    writeDelay: Double(writeDelay) / 1000,
                    interactive: interactive
                ),
                serviceFilter: filter,
                logger: LogWriter(path: logPath)
            )
            SnifferHolder.current = sniffer
            sniffer.start()
            dispatchMain()
        }
    }
}

// MARK: - 共通のパース

private func parseServiceFilter(_ text: String?) throws -> [CBUUID]? {
    guard let text else { return nil }
    guard let uuid = UUIDText.makeCBUUID(text) else {
        throw ValidationError("--filter-service の UUID が不正です: \(text)")
    }
    return [uuid]
}

/// `--write ffe1 0102 --write ffe2 03` のように 2 値ずつ与えられたトークン列を解釈する。
/// `--write ffe1=0102` 形式も受け付ける。
private func parseWrites(_ tokens: [String]) throws -> [PendingWrite] {
    var result = [PendingWrite]()
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        let uuidText: String
        let hexText: String
        if let separator = token.firstIndex(of: "="), separator != token.startIndex {
            uuidText = String(token[token.startIndex..<separator])
            hexText = String(token[token.index(after: separator)...])
            index += 1
        } else {
            guard index + 1 < tokens.count else {
                throw ValidationError("--write は <charUUID> <hex> の 2 値が必要です: \(token)")
            }
            uuidText = token
            hexText = tokens[index + 1]
            index += 2
        }
        guard UUIDText.makeCBUUID(uuidText) != nil else {
            throw ValidationError("--write の characteristic UUID が不正です: \(uuidText)")
        }
        guard let payload = Hex.parse(hexText) else {
            throw ValidationError("--write の hex が不正です（偶数桁の 16 進数で指定）: \(hexText)")
        }
        result.append(
            PendingWrite(
                characteristicUUID: UUIDText.canonical(uuidText),
                payload: payload,
                rawUUIDText: uuidText
            )
        )
    }
    return result
}
