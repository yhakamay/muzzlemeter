import Foundation

/// The connection state with the chronograph.
///
/// The device requires a key handshake right after connecting (`docs/PROTOCOL.md` §4.3),
/// so `pairing` is provided to represent that stage. The actual transition into it
/// starts being used once the handshake is implemented.
public enum ConnectionState: Sendable, Equatable {
    case idle
    case scanning
    case connecting
    case pairing
    case ready
    case disconnected(reason: String?)

    public var isReady: Bool { self == .ready }

    /// Whether some connection activity is in progress (i.e. it's OK to show the user
    /// "Connecting...").
    public var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .pairing: true
        case .idle, .ready, .disconnected: false
        }
    }
}

/// One "BB" setting held by the device.
///
/// Both `0x5A` (the currently selected BB) and `0x47` (a preset slot) carry these same
/// 4 bytes (`docs/PROTOCOL.md` §6.4).
///
/// **The scale is still a guess**, so `rawDiameter` / `rawWeight` are always exposed
/// alongside the converted value:
/// * The captured presets were `20 / 25 / 43 / 45 / 88`, and reading them as ×100 lines
///   up exactly with real 6 mm BB weights (0.20-0.88 g).
/// * But a spontaneous notification on real hardware showed `0x00c8 = 200` for that same
///   slot 1. At ×100 that's 2.00 g, not a real weight (at ×1000 it's 0.20 g).
///   **There may be two different unit systems in play.** Because of that, the UI must
///   not take `weightGrams` at face value, and should fall back to the raw value when it
///   needs to decide.
public struct AmmoRecord: Sendable, Hashable, Codable {
    /// The preset number (1-based).
    public let slot: Int
    /// The diameter's wire value. Presumed to be mm x 100 (measured as 600 = 6.00 mm on
    /// every slot).
    public let rawDiameter: UInt16
    /// The weight's wire value. Presumed to be g x 100 (see the caveat above).
    public let rawWeight: UInt16
    /// `true` if this came from `0x5A` (currently selected), `false` if from `0x47`
    /// (preset readout).
    public let isCurrent: Bool
    /// `0x47`'s payload[1]. Was 0x41 in the capture, but 0x40 in a spontaneous
    /// notification on real hardware. Presumed (**unverified**) to distinguish "read
    /// response" from "spontaneous notification." For `0x5A` this is payload[0].
    public let marker: UInt8

    public init(
        slot: Int,
        rawDiameter: UInt16,
        rawWeight: UInt16,
        isCurrent: Bool,
        marker: UInt8
    ) {
        self.slot = slot
        self.rawDiameter = rawDiameter
        self.rawWeight = rawWeight
        self.isCurrent = isCurrent
        self.marker = marker
    }

    /// The value `0x47`'s payload[1] takes when presumed to be a **spontaneous
    /// notification**. Observed during on-device testing (`docs/PROTOCOL.md` §6.3). A
    /// read response is `0x41`.
    public static let spontaneousMarker: UInt8 = 0x40

    /// Diameter (mm). The scale is **presumed** (measured as 600 = 6.00 mm on every slot).
    public var diameterMm: Double { Double(rawDiameter) / 100.0 }

    /// Weight (g). **Read leniently, since the scale isn't settled to just one value.**
    ///
    /// The captured presets were `20 / 25 / 43 / 45 / 88` (0.20-0.88 g at ×100), but a
    /// spontaneous notification on real hardware showed `200` for that same slot 1
    /// (0.20 g at ×1000). Real 6 mm BB weights run roughly 0.12-1.0 g, and
    ///
    /// * values that make sense at ×100 fall in the range 12-100
    /// * values that make sense at ×1000 fall in the range 120-1000
    ///
    /// which don't overlap. So this reads **×1000 if the value is 100 or more, ×100
    /// otherwise**. The boundary itself (is 100 = 1.00 g or 0.10 g?) isn't a real weight
    /// either way, so misreading it there doesn't land on a value that matters.
    ///
    /// Returns `nil` for 0 (unset), and for any value that doesn't become a real weight
    /// under either reading. **Staying silent rather than guessing a number** is the
    /// point — this value is used as the basis for the "does this not match the device's
    /// own setting?" warning.
    public var weightGrams: Double? {
        guard rawWeight > 0 else { return nil }
        let grams = rawWeight >= 100
            ? Double(rawWeight) / 1000.0
            : Double(rawWeight) / 100.0
        guard grams >= 0.10, grams <= 2.0 else { return nil }
        return grams
    }
}

/// An event delivered to the app from the chronograph.
///
/// `ChronoPacketDecoder` converts raw bytes into these, and `ChronoDevice` delivers them
/// as an `AsyncStream<ChronoEvent>`.
public enum ChronoEvent: Sendable, Equatable {
    case shot(Shot)
    case battery(percent: Int)
    case deviceInfo(model: String, firmware: String?)
    /// `0x41` ACK. `command` is the cmd being acknowledged (`0x4B` during the handshake).
    case ack(command: UInt8)
    /// `0x4E` NAK. A rejection response to an unknown command. **Confirmed on real
    /// hardware** (`docs/PROTOCOL.md` §6.7).
    case nak
    /// A BB setting (`0x5A` / `0x47`). **Arrives spontaneously from the device even when
    /// not requested.**
    case ammo(AmmoRecord)
    /// The device log's record count (`0x62`). payload[0] (**confirmed on real
    /// hardware**. `docs/PROTOCOL.md` §6.5). This log is volatile (resets to 0 records
    /// when the device is powered off).
    case logCount(Int)
    /// The **raw payload** of one device log record (`0x63`.
    /// `[index, rev0, rev1, speed0, speed1]`).
    ///
    /// Always delivered regardless of whether it could be interpreted (a hedge against
    /// unknown firmware variance). `index` is the number carried in the response
    /// (1-based. **Confirmed on real hardware**).
    case logRecordRaw(index: Int, payload: [UInt8])
    /// The above, read as one shot for the cases where a speed was present (i.e. an
    /// actual shot). velocity = raw `speed` / 100 m/s, `shot.rawRateOfFire` = raw `rev`
    /// (meaning not yet confirmed). **Confirmed on real hardware**
    /// (`docs/PROTOCOL.md` §6.6).
    case logRecord(index: Int, shot: Shot)
    /// An all-zero `0x63` response. Returned for an index past the record count, or an
    /// index with no record yet since power-on. **Not an error — it means "the log ends
    /// here"** (§6.6).
    case logRecordEmpty(index: Int)
    /// A 1-byte `00` notification = **the device powering off** (`docs/PROTOCOL.md`
    /// §5.1). Not an error. The link drops via supervision timeout about 0.76 s later.
    case powerOff
    case raw(characteristic: UUID, data: Data)
    case connectionState(ConnectionState)
    /// The list of devices found while scanning **has changed**.
    ///
    /// The same device's advertisement arrives many times per second, so this is only
    /// delivered when `DiscoveryList.upsert` reports that the contents actually changed.
    case discovered(DiscoveryList)
}

/// A swappable decoder that turns raw bytes into `ChronoEvent`.
///
/// `PassthroughDecoder` is used until the real protocol is confirmed; once confirmed, an
/// `AC6000PacketDecoder` (working name) is added and swapped in. A decoder may hold state
/// (to handle a stream being split or joined), but it must be `Sendable`.
public protocol ChronoPacketDecoder: Sendable {
    func decode(characteristic: UUID, data: Data) -> [ChronoEvent]
}

/// A decoder that can receive the checksum key after the fact.
///
/// The AC6000's checksum depends on the key (`docs/PROTOCOL.md` §3.1). The key comes
/// from the advertisement's manufacturer data, so it may still be unknown at the point
/// the decoder is created. `ChronoDevice` feeds it in through this once the key is
/// established at connect time.
public protocol ChronoKeyAwareDecoder: ChronoPacketDecoder {
    func updateKeys(_ keys: DeviceKeys)
}

/// A decoder that interprets nothing and just passes `.raw` through as-is. The default
/// while the protocol is still being reverse-engineered.
public struct PassthroughDecoder: ChronoPacketDecoder {
    public init() {}

    public func decode(characteristic: UUID, data: Data) -> [ChronoEvent] {
        [.raw(characteristic: characteristic, data: data)]
    }
}
