import AceChronoKit
import Foundation

/// 実機が無いときにアプリを動かすための再生ソース。
///
/// **デモ専用のエンコーディングはもう存在しない。** 流すバイト列は実プロトコル
/// （`docs/PROTOCOL.md`）そのもので、`AceChronoDecoder` が実機と同じように復号する。
/// 鍵ハンドシェイクも `ReplayTransport.demoPeripheral` が実機の広告
/// （`00 05 08 c4 94 52 04`）を持っているので同じ経路で成立する。
enum ReplaySupport {
    enum Source {
        /// 実キャプチャ（`acesoft-iphone-rx.txt`）。本物の 5 発が流れる。
        case capture
        /// UI 作り込み用に合成した射撃列。**バイト列は実プロトコルで組む。**
        case synthetic
    }

    /// `--replay` 起動、またはシミュレータで動かしているか。
    ///
    /// シミュレータには CoreBluetooth のハードウェアが無いので、常に再生にする。
    static var isEnabled: Bool {
        if CommandLine.arguments.contains("--replay") { return true }
        if CommandLine.arguments.contains("--replay-capture") { return true }
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// 既定は合成スクリプト（発数が多く UI を作りやすい）。
    /// `--replay-capture` を付けると実キャプチャを等倍で再生する。
    static var source: Source {
        CommandLine.arguments.contains("--replay-capture") ? .capture : .synthetic
    }

    static func makeTransport() -> ReplayTransport {
        switch source {
        case .capture:
            // 実キャプチャは 103 秒あり、最初の射撃が +50 秒。等倍だと待たされるので早送りする。
            ReplayTransport(script: captureScript(), speed: 6.0, repeats: true, loopGap: 3.0)
        case .synthetic:
            ReplayTransport(script: syntheticScript, speed: 1.0, repeats: true, loopGap: 4.0)
        }
    }

    /// バンドルした実キャプチャ。読めなければ合成スクリプトにフォールバックする。
    static func captureScript() -> ReplayScript {
        if let url = Bundle.main.url(forResource: "acesoft-iphone-rx", withExtension: "txt"),
           let loaded = try? ReplayScript.load(contentsOf: url),
           !loaded.entries.isEmpty {
            return loaded
        }
        return syntheticScript
    }

    // MARK: - 合成スクリプト（実プロトコルのバイト列）

    private static let keys = DeviceKeys(key1: 0xC4, key2: 0x94)
    private static let notify = ChronoUUIDs.notifyCharacteristic

    /// 単発 6 発 → フルオート 12 発。実機と同じ `0x52` フレームで組む。
    ///
    /// 先頭に `ACK(0x4B)` を置いてあるのは、再生でも鍵ハンドシェイクを成立させて
    /// `.ready` に到達させるため（実機の初期化と同じ順序）。
    static let syntheticScript: ReplayScript = {
        var entries = [ReplayEntry]()

        func append(_ offset: TimeInterval, _ data: Data) {
            entries.append(ReplayEntry(offsetSeconds: offset, characteristic: notify, data: data))
        }

        // 鍵ハンドシェイクの ACK と、現在の弾（6.00 mm / 0.20 g）。
        append(0.2, ChronoFrame(command: .ack, payload: [ChronoCommand.readKey.rawValue]).encode(keys: keys))
        append(
            0.6,
            ChronoFrame(command: .currentAmmo, payload: [0x01, 0x01, 0x58, 0x02, 0x14, 0x00]).encode(keys: keys)
        )

        func fireReport(metersPerSecond: Double, rawRev: UInt16 = 0) -> Data {
            let raw = UInt16(clamping: Int((metersPerSecond * FireReport.speedScale).rounded()))
            let payload: [UInt8] = [
                0x00, 0x00,
                UInt8(raw & 0xFF), UInt8(raw >> 8),
                UInt8(rawRev & 0xFF), UInt8(rawRev >> 8),
            ]
            return ChronoFrame(command: .fireReport, payload: payload).encode(keys: keys)
        }

        var offset: TimeInterval = 1.5
        for velocity in [91.2, 92.5, 90.8, 93.1, 92.0, 91.6] {
            append(offset, fireReport(metersPerSecond: velocity))
            offset += 1.6
        }
        offset += 1.5
        for velocity in [89.9, 90.4, 91.1, 90.2, 89.5, 90.9, 91.4, 90.0, 89.7, 90.6, 91.8, 90.3] {
            append(offset, fireReport(metersPerSecond: velocity))
            offset += 0.077   // ≒ 13 rps
        }
        return ReplayScript(entries: entries)
    }()
}
