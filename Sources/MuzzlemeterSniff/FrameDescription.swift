import MuzzlemeterKit
import Foundation

/// Formats received/sent raw bytes into a readable rendering of an AC6000 frame.
///
/// The key point is **reusing `MuzzlemeterKit`'s own codec as-is**. Having a second
/// implementation on the sniffer side would leave no way to tell which one is correct.
enum FrameDescription {
    /// The line shown next to the hex dump. `nil` if it can't be read as a frame.
    static func describe(_ data: Data, keys: DeviceKeys) -> String? {
        // A single 0x00 byte is the device's power-off signature (docs/PROTOCOL.md §5.1).
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

        case .nak:
            return name

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

        case .logCount where frame.payload.count >= 1:
            // payload = [count, fixed 0x01] (§6.5, confirmed on real hardware). The
            // second byte's meaning is unknown, so it's appended raw.
            let raw = frame.payload.count >= 2 ? String(format: " raw[1]=0x%02x", frame.payload[1]) : ""
            return "\(name) count=\(frame.payload[0])\(raw)"

        case .logRecord:
            // **Confirmed on real hardware** (`docs/PROTOCOL.md` §6.6). All-zero means
            // end of log (not an error).
            guard let record = DeviceLogWireRecord(payload: frame.payload) else {
                return "\(name) 応答レイアウトとして読めません  payload: \(payload)"
            }
            if record.isEmpty {
                return "\(name) index=\(record.index) 全ゼロ（ログの終端）  payload: \(payload)"
            }
            return String(
                format: "%@ index=%d rawSpeed=%d (%.2f m/s) rawRev=%d  payload: %@",
                name, record.index, Int(record.rawSpeed), record.metersPerSecond,
                Int(record.rawRateOfFire), payload
            )

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
