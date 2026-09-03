import Foundation

/// The contents of `FIRE_REPORT` (`0x52`).
///
/// ```
/// aa 0a 52 00 00 1a 01 00 00 79
///          ^^^^^ ^^^^^ ^^^^^
///          |     |     rawRev  (u16 LE)
///          |     rawSpeed (u16 LE)
///          always 0 (meaning unknown; presumed shot index / flags)
/// ```
public struct FireReport: Sendable, Hashable {
    /// payload[0..1]. Always 0 in measurements.
    public let flags: UInt16
    public let rawSpeed: UInt16
    public let rawRev: UInt16

    /// The speed scale. **Confirmed on real hardware** (`docs/PROTOCOL.md` §7.3): raw
    /// 325 / 278 / 375 were shown on the device's own LCD as 3.2 / 3.7 ... (the LCD
    /// display truncates). The conversion constant lives in this one place only.
    public static let speedScale: Double = 100.0

    public var metersPerSecond: Double { Double(rawSpeed) / Self.speedScale }

    public init(flags: UInt16 = 0, rawSpeed: UInt16, rawRev: UInt16 = 0) {
        self.flags = flags
        self.rawSpeed = rawSpeed
        self.rawRev = rawRev
    }

    /// Reads from a `0x52` frame's payload (6 bytes). `nil` if too short.
    public init?(payload: [UInt8]) {
        guard payload.count >= 6 else { return nil }
        self.init(
            flags: UInt16(payload[0]) | (UInt16(payload[1]) << 8),
            rawSpeed: UInt16(payload[2]) | (UInt16(payload[3]) << 8),
            rawRev: UInt16(payload[4]) | (UInt16(payload[5]) << 8)
        )
    }

    /// Reads a `0x63` (log record) payload **assuming it has the same layout as
    /// `FIRE_REPORT`**.
    ///
    /// **This is a guess.** A `0x63` response has never actually been observed
    /// (`docs/PROTOCOL.md` §6.6). The only basis for this is that, if the device returns
    /// "one shot's record," the same firmware most likely reuses the layout it already
    /// uses for `0x52` (`00 00 <speed LE16> <rev LE16>`).
    ///
    /// Because of that, the check here is **deliberately strict**:
    /// * at least 6 bytes (the `0x52` payload length)
    /// * flags (the first 2 bytes) are 0 — all 5 measured `0x52` shots had 0 here
    /// * rawSpeed > 0 — a 0 m/s shot can't be real
    ///
    /// Any deviation returns `nil`, and the caller **stops reading right there and saves
    /// the raw data instead**. Saving a merely-similar but different format as a "speed"
    /// would mix false numbers into the history that couldn't be told apart later.
    public static func logRecord(payload: [UInt8]) -> FireReport? {
        guard let report = FireReport(payload: payload),
              report.flags == 0,
              report.rawSpeed > 0
        else { return nil }
        return report
    }

    public func makeShot(timestamp: Date = Date()) -> Shot {
        Shot(
            timestamp: timestamp,
            velocityMetersPerSecond: metersPerSecond,
            // rawRev's unit isn't confirmed, so it isn't converted (see the doc comment
            // on `Shot.rateOfFireRPS`).
            rateOfFireRPS: nil,
            rawRateOfFire: rawRev
        )
    }
}

/// The response to `0x63` READ_LOG_RECORD (**confirmed on real hardware**.
/// `docs/PROTOCOL.md` §6.6).
///
/// ```
/// aa 09 63 01 00 00 81 01 f1
///          ^^ ^^^^^ ^^^^^
///          |  |     speed  (u16 LE) /100 -> m/s
///          |  rev   (u16 LE, meaning unconfirmed; kept as a raw value, same as
///          |         FIRE_REPORT's rawRev)
///          index (1-based; echoes back the requested index)
/// ```
///
/// Measured on 3 real shots (hand-tossed BBs): raw 385 / 359 / 407 -> /100 =
/// 3.85 / 3.59 / 4.07 m/s. Matched the device LCD's own history display
/// (3.8 / 3.5 / 4.0) (on-device testing, 2026-09-03/04).
///
/// Requesting index 0 gets no response. An index past the record count (`0x62`), or an
/// index with no record yet since power-on, returns an all-zero record — **both rev and
/// speed are 0**. This isn't an error; it means "the log ends here" (`isEmpty`).
public struct DeviceLogWireRecord: Sendable, Hashable {
    /// The index carried in the response (1-based).
    public let index: Int
    /// rev (meaning unconfirmed; exposed as a raw value, in the same role as
    /// FIRE_REPORT's rawRev).
    public let rawRateOfFire: UInt16
    /// The raw speed value. /100 gives m/s.
    public let rawSpeed: UInt16

    public init(index: Int, rawRateOfFire: UInt16, rawSpeed: UInt16) {
        self.index = index
        self.rawRateOfFire = rawRateOfFire
        self.rawSpeed = rawSpeed
    }

    /// Reads from a `0x63` frame's payload (5 bytes:
    /// `[index, rev0, rev1, speed0, speed1]`).
    public init?(payload: [UInt8]) {
        guard payload.count >= 5 else { return nil }
        self.init(
            index: Int(payload[0]),
            rawRateOfFire: UInt16(payload[1]) | (UInt16(payload[2]) << 8),
            rawSpeed: UInt16(payload[3]) | (UInt16(payload[4]) << 8)
        )
    }

    public var metersPerSecond: Double { Double(rawSpeed) / FireReport.speedScale }

    /// The all-zero record returned for an index past the record count, or an
    /// unrecorded index. No real shot has speed 0, so that alone is enough to detect it.
    public var isEmpty: Bool { rawSpeed == 0 }

    public func makeShot(timestamp: Date = Date()) -> Shot {
        Shot(
            timestamp: timestamp,
            velocityMetersPerSecond: metersPerSecond,
            rateOfFireRPS: nil,
            rawRateOfFire: rawRateOfFire
        )
    }
}

/// The real protocol decoder for the AC6000 MKIII BT.
///
/// Slices frames with `FrameAssembler`, then converts each one into a `ChronoEvent`
/// based on its cmd.
///
/// Design notes:
/// * **Holds state** (buffers across notifications that arrive split or joined).
///   `ChronoPacketDecoder`'s `decode` is non-mutating, so internal state is guarded by a
///   lock (`@unchecked Sendable`).
/// * **The key can be plugged in later** (`ChronoKeyAwareDecoder`). Since the key comes
///   from the advertisement's manufacturer data, it may still be unknown when the
///   decoder is created.
/// * **Never discards a frame just because it's unrecognized.** Both unknown cmds and
///   checksum mismatches are passed through as `.raw`. The device sends frames that
///   weren't requested (spontaneous `0x47` / `0x5A` notifications), so "unexpected frame
///   = error" would be wrong.
public final class MuzzlemeterDecoder: ChronoKeyAwareDecoder, @unchecked Sendable {
    /// How strict checksum validation is.
    public enum ChecksumPolicy: Sendable, Hashable {
        /// A frame whose checksum matches neither the keyed sum nor the unkeyed sum
        /// falls back to `.raw`.
        case strict
        /// Skips validation while the key is still unestablished (0/0). Behaves like
        /// `strict` once the key is known.
        ///
        /// The default. During first-time pairing (key unknown), the device's response
        /// can't be validated yet — rejecting it here would mean the `0x4B` response
        /// that delivers the key could never be read.
        case lenientUntilKeysKnown
        /// Never validates (for analysis / debugging).
        case ignore
    }

    private let lock = NSLock()
    private var assembler = FrameAssembler()
    private let policy: ChecksumPolicy
    /// The injection point for the current time (so tests can be deterministic).
    private let now: @Sendable () -> Date

    public init(
        keys: DeviceKeys = .zero,
        policy: ChecksumPolicy = .lenientUntilKeysKnown,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.now = now
        self.assembler.keys = keys
        self.assembler.acceptsUnkeyedChecksum = true
    }

    /// The current key.
    public var keys: DeviceKeys {
        lock.lock()
        defer { lock.unlock() }
        return assembler.keys
    }

    public func updateKeys(_ keys: DeviceKeys) {
        lock.lock()
        defer { lock.unlock() }
        assembler.keys = keys
    }

    /// Discards the buffer when the connection drops, so a half-built frame never
    /// survives across a disconnect.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        assembler.reset()
    }

    public func decode(characteristic: UUID, data: Data) -> [ChronoEvent] {
        lock.lock()
        let outputs = assembler.append(data)
        let keysKnown = !assembler.keys.isZero
        lock.unlock()

        var events = [ChronoEvent]()
        events.reserveCapacity(outputs.count)
        for output in outputs {
            switch output {
            case .powerOff:
                events.append(.powerOff)
            case .frame(let frame, let raw):
                events.append(contentsOf: decode(frame: frame, raw: raw, characteristic: characteristic))
            case .invalid(let raw, let error):
                // If the only problem is the checksum and the key isn't established yet,
                // keep reading anyway.
                if case .checksumMismatch = error,
                   shouldAcceptUnverified(keysKnown: keysKnown),
                   let frame = Self.frameIgnoringChecksum(raw) {
                    events.append(contentsOf: decode(frame: frame, raw: raw, characteristic: characteristic))
                } else {
                    events.append(.raw(characteristic: characteristic, data: raw))
                }
            }
        }
        return events
    }

    private func shouldAcceptUnverified(keysKnown: Bool) -> Bool {
        switch policy {
        case .strict: false
        case .ignore: true
        case .lenientUntilKeysKnown: !keysKnown
        }
    }

    /// Builds a frame from just the header/length, without checking the checksum (a
    /// fallback for while the key is still unestablished).
    private static func frameIgnoringChecksum(_ raw: Data) -> ChronoFrame? {
        let bytes = [UInt8](raw)
        guard bytes.count >= ChronoFrame.minimumLength, bytes[0] == ChronoFrame.header,
              Int(bytes[1]) == bytes.count
        else { return nil }
        return ChronoFrame(cmd: bytes[2], payload: Array(bytes[3..<(bytes.count - 1)]))
    }

    // MARK: - Interpreting each cmd

    private func decode(frame: ChronoFrame, raw: Data, characteristic: UUID) -> [ChronoEvent] {
        // An unknown cmd is passed up unchanged as .raw (the device also sends
        // undocumented frames).
        guard let command = frame.command else {
            return [.raw(characteristic: characteristic, data: raw)]
        }
        switch command {
        case .fireReport:
            guard let report = FireReport(payload: frame.payload) else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            return [.shot(report.makeShot(timestamp: now()))]

        case .ack:
            guard let target = frame.payload.first else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            return [.ack(command: target)]

        case .nak:
            // The payload is fixed at 0xFF (a rejection of an unknown command).
            // **Confirmed on real hardware** (§6.7).
            return [.nak]

        case .currentAmmo:
            // aa 0a 5a 01 <slot> <ammo:4> cks
            guard frame.payload.count >= 6 else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            let record = AmmoRecord(
                slot: Int(frame.payload[1]),
                rawDiameter: le16(frame.payload, 2),
                rawWeight: le16(frame.payload, 4),
                isCurrent: true,
                marker: frame.payload[0]
            )
            return [.ammo(record)]

        case .ammoPreset:
            // aa 0b 47 <status> <marker> <idx> <ammo:4> cks
            // marker was observed as either 0x41 (read response) or 0x40 (spontaneous
            // notification). Both are valid frames, so this doesn't reject on the value.
            guard frame.payload.count >= 7 else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            let record = AmmoRecord(
                slot: Int(frame.payload[2]),
                rawDiameter: le16(frame.payload, 3),
                rawWeight: le16(frame.payload, 5),
                isCurrent: false,
                marker: frame.payload[1]
            )
            return [.ammo(record)]

        case .logCount:
            // aa 06 62 <count> <fixed 0x01> cks. **Confirmed on real hardware** (§6.5):
            // payload[0] = the record count (including 0), payload[1] is always 0x01 and
            // its meaning is unknown (kept raw, uninterpreted — a previous implementation
            // mistakenly read payload[1] as the count).
            guard let count = frame.payload.first else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            return [.logCount(Int(count))]

        case .batteryReport, .batteryQuery:
            // **Unverified**: never once appeared in a capture. Assumed, by analogy with
            // other responses, to be payload = [status, value]; if only 1 byte, treated
            // as the value itself.
            guard let percent = frame.payload.count >= 2 ? frame.payload[1] : frame.payload.first
            else { return [.raw(characteristic: characteristic, data: raw)] }
            return [.battery(percent: Int(min(percent, 100)))]

        case .logRecord:
            // **Confirmed on real hardware** (§6.6): payload = [index, rev0, rev1,
            // speed0, speed1]. Always emits the raw payload first, followed by either
            // "all-zero (end of log)" or "one shot successfully read." The raw event
            // goes out first so that even a future firmware variance that fails to parse
            // can still be picked up in the same place.
            guard let record = DeviceLogWireRecord(payload: frame.payload) else {
                return [.raw(characteristic: characteristic, data: raw)]
            }
            var events: [ChronoEvent] = [.logRecordRaw(index: record.index, payload: frame.payload)]
            if record.isEmpty {
                events.append(.logRecordEmpty(index: record.index))
            } else {
                events.append(.logRecord(index: record.index, shot: record.makeShot(timestamp: now())))
            }
            return events

        case .readKey, .readDeviceSettings:
            // The 0x4B response (key exchange) is read by ChronoDevice from the raw
            // bytes during the handshake. It's passed through uninterpreted here.
            return [.raw(characteristic: characteristic, data: raw)]
        }
    }

    private func le16(_ payload: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < payload.count else { return 0 }
        return UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
    }
}
