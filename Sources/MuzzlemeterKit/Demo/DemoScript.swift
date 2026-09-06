import Foundation

/// The synthetic packet stream demo mode plays back.
///
/// **There is no demo-only encoding.** The bytes below are the real protocol
/// (`docs/PROTOCOL.md`) and `MuzzlemeterDecoder` decodes them exactly as it decodes real
/// hardware. `ReplayTransport.demoPeripheral` even carries the real device's own
/// advertisement (`00 05 08 c4 94 52 04`), so the key handshake succeeds through the same
/// path. That is the whole point of demo mode: it exercises the shipping code, not a
/// parallel one.
///
/// The stream is a plausible airsoft session rather than the bench capture: an AEG around
/// **90 m/s on 0.20 g BBs** (≈0.81 J, comfortably under the Japanese 0.98 J limit but
/// close enough that the headroom line is interesting), fired as a handful of semi-auto
/// shots and then one short full-auto burst at ≈13 rounds per second.
public enum DemoScript {
    /// The device keys the demo peripheral advertises (`c4 94`).
    public static let keys = DeviceKeys(key1: 0xC4, key2: 0x94)

    /// The semi-auto shots, in order (m/s).
    ///
    /// Spread is about ±1 m/s around 92, which is what a well-set-up AEG actually does;
    /// a perfectly flat series would make the standard-deviation and extreme-spread
    /// statistics look broken.
    public static let semiAutoVelocities: [Double] = [91.2, 92.5, 90.8, 93.1, 92.0, 91.6]

    /// The full-auto burst, in order (m/s).
    ///
    /// Slightly lower and slightly tighter than the semi-auto shots — an AEG's velocity
    /// usually sags a little once the gearbox is running continuously.
    public static let burstVelocities: [Double] = [
        89.9, 90.4, 91.1, 90.2, 89.5, 90.9, 91.4, 90.0, 89.7, 90.6, 91.8, 90.3,
    ]

    /// The BB weight the mock device reports it is set to (g).
    ///
    /// Kept at 0.20 g because that is what the payload below says. If the app's session
    /// weight and the device's weight disagree, the "ammo mismatch" banner stays on
    /// screen for the whole demo.
    public static let deviceBBWeightGrams = 0.20

    /// The seconds between semi-auto shots.
    public static let semiAutoInterval: TimeInterval = 1.6

    /// The seconds between shots inside the burst (≈13 rps).
    public static let burstInterval: TimeInterval = 0.077

    /// The full script: handshake ACK, the current-ammo report, then the shots.
    ///
    /// The leading `ACK(0x4B)` is what gets a replay to `.ready`, in the same order real
    /// hardware initializes in.
    public static func script(keys: DeviceKeys = DemoScript.keys) -> ReplayScript {
        var entries = [ReplayEntry]()
        let notify = ChronoUUIDs.notifyCharacteristic

        func append(_ offset: TimeInterval, _ data: Data) {
            entries.append(ReplayEntry(offsetSeconds: offset, characteristic: notify, data: data))
        }

        append(0.2, ChronoFrame(command: .ack, payload: [ChronoCommand.readKey.rawValue]).encode(keys: keys))
        // 6.00 mm / 0.20 g, the same layout the real device sends (`docs/PROTOCOL.md` §6.2).
        append(
            0.6,
            ChronoFrame(command: .currentAmmo, payload: [0x01, 0x01, 0x58, 0x02, 0x14, 0x00]).encode(keys: keys)
        )

        var offset: TimeInterval = 1.5
        for velocity in semiAutoVelocities {
            append(offset, fireReport(metersPerSecond: velocity, keys: keys))
            offset += semiAutoInterval
        }
        // A pause before the burst, so the "rate of fire" statistic visibly changes when
        // the burst starts instead of being averaged away.
        offset += 1.5
        for velocity in burstVelocities {
            append(offset, fireReport(metersPerSecond: velocity, keys: keys))
            offset += burstInterval
        }
        return ReplayScript(entries: entries)
    }

    /// One `0x52` fire report, encoded with the real frame layout.
    public static func fireReport(
        metersPerSecond: Double,
        rawRev: UInt16 = 0,
        keys: DeviceKeys = DemoScript.keys
    ) -> Data {
        let raw = UInt16(clamping: Int((metersPerSecond * FireReport.speedScale).rounded()))
        let payload: [UInt8] = [
            0x00, 0x00,
            UInt8(raw & 0xFF), UInt8(raw >> 8),
            UInt8(rawRev & 0xFF), UInt8(rawRev >> 8),
        ]
        return ChronoFrame(command: .fireReport, payload: payload).encode(keys: keys)
    }

    /// Every velocity in the script, in playback order.
    public static var allVelocities: [Double] { semiAutoVelocities + burstVelocities }

    /// A `ReplayTransport` playing this script on a loop, for demo mode.
    ///
    /// The mock firmware answers the device-log request with **0 records**, so the
    /// "import the device's internal log" banner stays out of the way during a demo while
    /// the request/response round trip is still exercised.
    public static func makeTransport(
        speed: Double = 1.0,
        loopGap: TimeInterval = 4.0
    ) -> ReplayTransport {
        ReplayTransport(
            script: script(),
            speed: speed,
            repeats: true,
            loopGap: loopGap,
            responder: ReplayTransport.deviceLogResponder(count: 0, keys: keys)
        )
    }
}
