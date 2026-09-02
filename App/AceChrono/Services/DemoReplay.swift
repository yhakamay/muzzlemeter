import AceChronoKit
import Foundation

/// **UI 開発専用**のデモ用パケット定義。
///
/// 実機のパケット形式はまだ解析中（`docs/PROTOCOL-apk-analysis.md` §8）なので、
/// ここで使うエンコーディングは**このアプリのために勝手に決めたもの**であり、
/// AC6000 のプロトコルとは一切関係ない。プロトコルが確定したら
/// `AC6000PacketDecoder` に置き換えて、このファイルごと消す。
///
/// エンコーディング（4 バイト）:
/// ```
/// offset 0..1  UInt16 LE  速度 (m/s) × 100
/// offset 2..3  UInt16 LE  連射速度 (rps) × 100  （0 = 報告なし＝単発）
/// ```
enum DemoProtocol {
    /// デモが使う characteristic（本物の UUID ではない）。
    static let characteristic = BluetoothUUID.short(0xFFE1)

    static func encode(velocityMetersPerSecond: Double, rateOfFireRPS: Double?) -> Data {
        let speed = UInt16(clamping: Int((velocityMetersPerSecond * 100).rounded()))
        let rev = UInt16(clamping: Int(((rateOfFireRPS ?? 0) * 100).rounded()))
        return Data([
            UInt8(speed & 0xFF), UInt8(speed >> 8),
            UInt8(rev & 0xFF), UInt8(rev >> 8),
        ])
    }
}

/// デモ用バイト列を `ChronoEvent.shot` に変換するデコーダ。
struct DemoDecoder: ChronoPacketDecoder {
    func decode(characteristic: UUID, data: Data) -> [ChronoEvent] {
        guard data.count == 4 else { return [.raw(characteristic: characteristic, data: data)] }
        let bytes = [UInt8](data)
        let rawSpeed = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let rawRev = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        return [
            .shot(
                Shot(
                    velocityMetersPerSecond: Double(rawSpeed) / 100.0,
                    rateOfFireRPS: rawRev == 0 ? nil : Double(rawRev) / 100.0
                )
            )
        ]
    }
}

enum DemoReplay {
    /// `--replay` 起動、またはシミュレータで動かしているか。
    ///
    /// シミュレータには CoreBluetooth のハードウェアが無いので、常にリプレイにする。
    static var isEnabled: Bool {
        if CommandLine.arguments.contains("--replay") { return true }
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// バンドルされた `demo-replay.txt`。読めない場合は組み込みのフォールバックを返す。
    static func script() -> ReplayScript {
        if let url = Bundle.main.url(forResource: "demo-replay", withExtension: "txt"),
           let loaded = try? ReplayScript.load(contentsOf: url),
           !loaded.entries.isEmpty {
            return loaded
        }
        return fallbackScript
    }

    /// Preview やリソース読み込み失敗時のための、コード内で組み立てるスクリプト。
    static let fallbackScript: ReplayScript = {
        var entries = [ReplayEntry]()
        var offset: TimeInterval = 0.5
        let singles: [Double] = [91.2, 92.5, 90.8, 93.1, 92.0]
        for velocity in singles {
            entries.append(
                ReplayEntry(
                    offsetSeconds: offset,
                    characteristic: DemoProtocol.characteristic,
                    data: DemoProtocol.encode(velocityMetersPerSecond: velocity, rateOfFireRPS: nil)
                )
            )
            offset += 1.5
        }
        for velocity in [89.9, 90.4, 91.1, 90.2, 89.5] {
            entries.append(
                ReplayEntry(
                    offsetSeconds: offset,
                    characteristic: DemoProtocol.characteristic,
                    data: DemoProtocol.encode(velocityMetersPerSecond: velocity, rateOfFireRPS: 13.2)
                )
            )
            offset += 0.08
        }
        return ReplayScript(entries: entries)
    }()

    static func makeTransport() -> ReplayTransport {
        ReplayTransport(script: script(), speed: 1.0, repeats: true, loopGap: 4.0)
    }
}
