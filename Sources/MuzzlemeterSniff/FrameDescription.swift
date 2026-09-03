import MuzzlemeterKit
import Foundation

/// 受信・送信した生バイト列を、AC6000 のフレームとして読める形に整形する。
///
/// **`MuzzlemeterKit` のコーデックをそのまま使う**のが要点。サニファ側に 2 つ目の
/// 実装を持つと、どちらが正しいのか分からなくなる。
enum FrameDescription {
    /// hex の隣に出す 1 行。フレームとして読めなければ `nil`。
    static func describe(_ data: Data, keys: DeviceKeys) -> String? {
        // 1 バイトの 00 は本体の電源 OFF シグネチャ（docs/PROTOCOL.md §5.1）。
        if data.count == 1, data.first == 0x00 {
            return "POWER_OFF（本体の電源 OFF。約 0.76 秒後に切断される）"
        }

        let result = ChronoFrame.decode(data, keys: keys, acceptUnkeyedChecksum: true)
        switch result {
        case .failure(let error):
            return "不正フレーム: \(error)"
        case .success(let frame):
            return describe(frame)
        }
    }

    private static func describe(_ frame: ChronoFrame) -> String {
        let name = ChronoCommand.describe(frame.cmd)
        let payload = frame.payload.map { String(format: "%02x", $0) }.joined(separator: " ")

        switch frame.command {
        case .ack:
            let target = frame.payload.first.map { ChronoCommand.describe($0) } ?? "?"
            return "\(name) for \(target)"

        case .fireReport:
            guard let report = FireReport(payload: frame.payload) else { break }
            return String(
                format: "%@ rawSpeed=%d (%.2f m/s) rawRev=%d flags=%d",
                name, Int(report.rawSpeed), report.metersPerSecond, Int(report.rawRev), Int(report.flags)
            )

        case .currentAmmo where frame.payload.count >= 6:
            let diameter = le16(frame.payload, 2)
            let weight = le16(frame.payload, 4)
            return String(
                format: "%@ slot=%d 直径raw=%d (%.2f mm) 重量raw=%d (%.2f g?)",
                name, Int(frame.payload[1]), Int(diameter), Double(diameter) / 100,
                Int(weight), Double(weight) / 100
            )

        case .ammoPreset where frame.payload.count >= 7:
            let diameter = le16(frame.payload, 3)
            let weight = le16(frame.payload, 5)
            return String(
                format: "%@ status=%02x marker=%02x slot=%d 直径raw=%d 重量raw=%d",
                name, Int(frame.payload[0]), Int(frame.payload[1]), Int(frame.payload[2]),
                Int(diameter), Int(weight)
            )

        case .logCount where frame.payload.count >= 2:
            return "\(name) count=\(frame.payload[1])（status=\(frame.payload[0])）"

        case .readKey where frame.payload.count >= 2:
            return String(
                format: "%@ key1=0x%02x key2=0x%02x", name, Int(frame.payload[0]), Int(frame.payload[1])
            )

        default:
            break
        }
        return payload.isEmpty ? name : "\(name) payload: \(payload)"
    }

    private static func le16(_ payload: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < payload.count else { return 0 }
        return UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
    }
}
