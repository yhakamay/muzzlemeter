import Foundation

/// One record from the device's internal log.
///
/// The format is **confirmed on real hardware** (`docs/PROTOCOL.md` §6.6), but the raw
/// payload is always carried alongside it too. A record whose `shot` is `nil` means the
/// response couldn't be interpreted, and the caller stops reading there and saves the
/// raw data (a hedge against unknown firmware variance).
public struct DeviceLogRecord: Sendable, Hashable {
    /// The index carried in the response (1-based).
    public let index: Int
    /// The `0x63` frame's payload (from right after cmd up to just before the checksum).
    public let payload: [UInt8]
    /// The shot this parsed into, if it carried a speed. **Confirmed on real hardware.**
    public let shot: Shot?

    public init(index: Int, payload: [UInt8], shot: Shot?) {
        self.index = index
        self.payload = payload
        self.shot = shot
    }

    public var isParsed: Bool { shot != nil }

    /// A one-line debug form: `<index> <payload hex>`.
    ///
    /// Kept in a form the user can paste and send back as-is. **This is the only path to
    /// getting an actual "real `0x63` response"**, so it's always kept even when parsing
    /// fails.
    public var hexLine: String {
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "\(index) \(hex)"
    }
}

/// Where a readout ended.
public enum DeviceLogOutcome: Sendable, Hashable {
    /// Read through the whole requested range (including the case of 0 records, and the
    /// case of reaching the end of the log via an all-zero record — §6.6's "all-zero
    /// means end" isn't an error).
    case completed
    /// This record couldn't be parsed as a `0x63` response, so reading **stopped right
    /// there**. The raw data is saved so the user can send it back. Shouldn't normally
    /// happen once the format is confirmed on real hardware, but kept as a hedge against
    /// unknown firmware variance.
    case unsupportedFormat(index: Int)
    /// No response arrived. If `index` is `nil`, it didn't even arrive at the count
    /// (`0x62`) stage.
    case timedOut(index: Int?)
    /// The readout couldn't be started (not connected / no write target / already
    /// reading).
    case unavailable(String)
}

/// The result of reading the device's internal log.
public struct DeviceLogReadResult: Sendable, Hashable {
    /// The count `0x62` reported. 0 if it couldn't be read.
    public let reportedCount: Int
    /// The records received (in order; includes an unparseable one at the end too).
    public let records: [DeviceLogRecord]
    public let outcome: DeviceLogOutcome

    public init(reportedCount: Int, records: [DeviceLogRecord], outcome: DeviceLogOutcome) {
        self.reportedCount = reportedCount
        self.records = records
        self.outcome = outcome
    }

    /// The ones that parsed as a shot. **Only these may be saved into a session.**
    public var shots: [Shot] { records.compactMap(\.shot) }

    public var isComplete: Bool { outcome == .completed }

    /// Whether nothing was received at all (nothing to save).
    public var isEmpty: Bool { shots.isEmpty }

    /// The last index actually read. Used to advance the "how far has been imported"
    /// marker when reading a volatile log incrementally (`nil` if nothing was read).
    public var lastReadIndex: Int? { records.last?.index }
}

/// How device-log reads are paced.
///
/// Matches the initialization sequence observed in measurements
/// (`docs/PROTOCOL.md` §4.2): sent **one at a time, waiting for the response, about
/// 300 ms apart**. Never sent in a batch.
public struct DeviceLogReadOptions: Sendable, Hashable {
    /// The wait for each response. Measured responses take 45-63 ms, so 3 seconds is
    /// plenty.
    public var responseTimeout: TimeInterval
    /// The gap before the next command.
    public var commandGap: TimeInterval
    /// A safety valve: even if the device reports a broken count, stop at this many.
    public var maximumRecords: Int
    /// The 1-based index to start reading from.
    ///
    /// The device's internal log is **volatile** (resets to 0 records on power-off). To
    /// avoid re-reading records already imported during the same power cycle, the caller
    /// (`ChronoService`) remembers "how far it read last time" and passes in where to
    /// continue from. Defaults to 1 (read everything from the start).
    public var startIndex: Int

    public init(
        responseTimeout: TimeInterval = 3.0,
        commandGap: TimeInterval = 0.3,
        maximumRecords: Int = 200,
        startIndex: Int = 1
    ) {
        self.responseTimeout = responseTimeout
        self.commandGap = commandGap
        self.maximumRecords = maximumRecords
        self.startIndex = max(1, startIndex)
    }
}

/// How far a readout has progressed (`done / total`).
public struct DeviceLogProgress: Sendable, Hashable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}
