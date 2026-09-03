import Foundation

/// A `ChronoTransport` that plays back recorded packets along their original timeline.
///
/// Uses:
/// - **Simulator / SwiftUI Preview**: builds out the Live screen without real hardware
/// - **Tests**: with `speed = 0`, every packet is delivered in order with no waiting at
///   all, so deterministic tests can be written that don't depend on timing
///
/// Playback starts on the **first `subscribe(to:)`**. Matching the same order as real
/// hardware (scan -> connect -> subscribe -> receive) means `ChronoDevice`'s own code
/// never needs to branch on which transport implementation is in use. Entries for a
/// characteristic that isn't subscribed to are dropped.
public actor ReplayTransport: ChronoTransport {
    /// A record of a write (so tests can verify initialization commands were sent).
    public struct RecordedWrite: Sendable, Hashable {
        public let characteristic: UUID
        public let data: Data
        public let withResponse: Bool
    }

    /// Mock firmware that **responds on the spot** to a written frame.
    ///
    /// Playing back recorded packets alone can't carry a "request -> response"
    /// round trip (e.g. `0x62` / `0x63` log reads). This lets a function that builds the
    /// response frame for a given request be plugged in, so **the app side goes through
    /// the same path as real hardware** (write -> notify). A request with no response
    /// returns an empty array.
    ///
    /// The current `deviceLogResponder` (below) answers using the **response format
    /// confirmed on real hardware** for 0x62 / 0x63 (`docs/PROTOCOL.md` §6.5 / §6.6).
    public typealias Responder = @Sendable (Data) -> [Data]

    private let script: ReplayScript
    /// The playback speed. 1.0 is real time, 2.0 is double speed. **0 means no waiting
    /// at all.**
    private let speed: Double
    private let peripheral: DiscoveredPeripheral
    /// Whether to loop back to the start after playing through to the end (for demos).
    /// Ignored when `speed == 0`.
    private let repeats: Bool
    private let loopGap: TimeInterval
    private let responder: Responder?
    /// The delay before a response is delivered. Real hardware responses measured
    /// 45-63 ms (`docs/PROTOCOL.md` §4.2).
    private let responseDelay: TimeInterval
    /// The characteristic responses are delivered on (the same notify side as real
    /// hardware).
    private let responseCharacteristic: UUID

    public nonisolated let events: AsyncStream<TransportEvent>
    private nonisolated let continuation: AsyncStream<TransportEvent>.Continuation

    private var subscribedCharacteristics = Set<UUID>()
    private var replayTask: Task<Void, Never>?
    private var connected = false
    public private(set) var writes = [RecordedWrite]()

    public init(
        script: ReplayScript,
        speed: Double = 1.0,
        peripheral: DiscoveredPeripheral = ReplayTransport.demoPeripheral,
        repeats: Bool = false,
        loopGap: TimeInterval = 2.0,
        responder: Responder? = nil,
        responseDelay: TimeInterval = 0.05,
        responseCharacteristic: UUID = ChronoUUIDs.notifyCharacteristic
    ) {
        self.script = script
        self.speed = max(0, speed)
        self.peripheral = peripheral
        self.repeats = repeats
        self.loopGap = loopGap
        self.responder = responder
        self.responseDelay = max(0, responseDelay)
        self.responseCharacteristic = responseCharacteristic
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    /// The mock peripheral used for playback.
    ///
    /// Its manufacturer data carries **the real device's own advertisement**
    /// (`00 05 08 c4 94 52 04`) as-is. That lets `ChronoDevice` extract the key
    /// `c4/94` through the same path as real hardware, so even checksum validation of
    /// the recorded frames runs through the same code as production.
    public static let demoPeripheral = DiscoveredPeripheral(
        id: UUID(uuidString: "00000000-0000-0000-0000-ACEC40000000") ?? UUID(),
        name: "AC6000BT-DEMO",
        rssi: -52,
        advertisedServices: [],
        manufacturerData: Data([0x00, 0x05, 0x08, 0xC4, 0x94, 0x52, 0x04])
    )

    // MARK: - ChronoTransport

    public func scan(services: [UUID]?, nameFilter: String?) async throws {
        // Only matched when a name filter is given. The service filter has no meaning
        // during playback, so it's ignored.
        if let nameFilter, !nameFilter.isEmpty {
            let name = peripheral.name?.lowercased() ?? ""
            guard name.contains(nameFilter.lowercased()) else { return }
        }
        continuation.yield(.discovered(peripheral))
    }

    public func stopScan() async {}

    public func connect(to peripheralID: UUID) async throws {
        guard peripheralID == peripheral.id else {
            throw ChronoTransportError.unavailable("未知の peripheral: \(peripheralID)")
        }
        connected = true
        continuation.yield(.connected(peripheral: peripheral.id))
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        replayTask?.cancel()
        replayTask = nil
        subscribedCharacteristics.removeAll()
        continuation.yield(.disconnected(peripheral: peripheral.id, reason: nil))
    }

    public func subscribe(to characteristic: UUID) async throws {
        guard connected else { throw ChronoTransportError.notConnected }
        subscribedCharacteristics.insert(characteristic)
        continuation.yield(.subscribed(characteristic: characteristic))
    }

    /// Starts playback only once every subscription is in place. Called by
    /// `ChronoDevice` after subscribing and sending any initialization writes.
    public func finishSetup() async {
        startReplayIfNeeded()
    }

    public func write(_ data: Data, to characteristic: UUID, withResponse: Bool) async throws {
        guard connected else { throw ChronoTransportError.notConnected }
        writes.append(RecordedWrite(characteristic: characteristic, data: data, withResponse: withResponse))
        respond(to: data)
    }

    /// Delivers the mock firmware's response.
    ///
    /// The key point is **delivering it from a separate task**. The caller of `write`
    /// is waiting for the response, so yielding directly here would technically work
    /// too, but matching real hardware's "notify arrives a little later" ordering means
    /// the implementation also exercises the case where a response arrives before the
    /// wait has even started.
    private func respond(to request: Data) {
        guard let responder else { return }
        let responses = responder(request)
        guard !responses.isEmpty else { return }
        guard subscribedCharacteristics.contains(responseCharacteristic) else { return }
        let characteristic = responseCharacteristic
        let delay = responseDelay
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.emit(responses, on: characteristic)
        }
    }

    private func emit(_ responses: [Data], on characteristic: UUID) {
        guard connected else { return }
        for response in responses {
            continuation.yield(.value(characteristic: characteristic, data: response))
        }
    }

    public func shutdown() async {
        replayTask?.cancel()
        replayTask = nil
        connected = false
        continuation.finish()
    }

    // MARK: - Playback

    private func startReplayIfNeeded() {
        guard replayTask == nil else { return }
        replayTask = Task { [weak self] in
            await self?.runReplay()
        }
    }

    private func runReplay() async {
        // With speed == 0 (tests), repeats is disabled to avoid an infinite loop.
        let shouldRepeat = repeats && speed > 0
        repeat {
            var previousOffset: TimeInterval = 0
            for entry in script.entries {
                if Task.isCancelled { return }
                if speed > 0 {
                    let wait = (entry.offsetSeconds - previousOffset) / speed
                    if wait > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }
                } else {
                    // Even without waiting, still yield cooperatively for scheduling.
                    await Task.yield()
                }
                previousOffset = entry.offsetSeconds
                if Task.isCancelled { return }
                guard connected else { return }
                guard subscribedCharacteristics.contains(entry.characteristic) else { continue }
                continuation.yield(.value(characteristic: entry.characteristic, data: entry.data))
            }
            if shouldRepeat {
                try? await Task.sleep(nanoseconds: UInt64(max(0, loopGap / speed) * 1_000_000_000))
            }
        } while shouldRepeat && !Task.isCancelled
    }
}

// MARK: - Mock firmware

extension ReplayTransport {
    /// Mock firmware that responds to device-log reads (`0x62` / `0x63`).
    ///
    /// Answers using the **response format confirmed on real hardware**
    /// (`docs/PROTOCOL.md` §6.5 / §6.6, from on-device testing on 2026-09-03/04):
    /// * `0x62` -> `[count, 0x01]`
    /// * `0x63` (1-byte, 1-based index) -> `[index, rev0, rev1, speed0, speed1]`.
    ///   Doesn't respond to index 0. An index past `count` returns an all-zero record
    ///   (not an error — it means "end of log").
    ///
    /// - Parameters:
    ///   - count: the record count `0x62` answers with.
    ///   - brokenIndex: only this record number is returned in an **unparseable form**
    ///     (a too-short payload). Needed to exercise the defensive fallback path for
    ///     unknown firmware variance without real hardware. Shouldn't normally happen on
    ///     real hardware.
    ///   - speeds: the records' speeds (m/s). Cycled through if there aren't enough.
    public static func deviceLogResponder(
        count: Int,
        keys: DeviceKeys = DeviceKeys(key1: 0xC4, key2: 0x94),
        brokenIndex: Int? = nil,
        speeds: [Double] = [88.4, 89.1, 90.6, 91.3, 87.9, 92.2, 90.0, 88.8]
    ) -> Responder {
        { request in
            let bytes = [UInt8](request)
            guard bytes.count >= 4, bytes[0] == ChronoFrame.header else { return [] }
            switch bytes[2] {
            case ChronoCommand.logCount.rawValue:
                // aa 06 62 <count> <fixed 0x01> cks (§6.5, confirmed on real hardware)
                return [
                    ChronoFrame(command: .logCount, payload: [UInt8(clamping: count), 0x01])
                        .encode(keys: keys)
                ]

            case ChronoCommand.logRecord.rawValue:
                // A 1-byte, 1-based index. No response for index 0 (confirmed on real
                // hardware).
                guard bytes.count >= 5 else { return [] }
                let index = Int(bytes[3])
                guard index > 0 else { return [] }
                if index == brokenIndex {
                    // Fewer than 5 bytes = unparseable as the response layout (for the
                    // defensive fallback path).
                    return [ChronoFrame(command: .logRecord, payload: [UInt8(index), 0x00]).encode(keys: keys)]
                }
                guard index <= count else {
                    // An index past the record count gets an all-zero record (end of
                    // log; not an error).
                    return [
                        ChronoFrame(command: .logRecord, payload: [UInt8(index), 0x00, 0x00, 0x00, 0x00])
                            .encode(keys: keys)
                    ]
                }
                let speed = speeds.isEmpty ? 90.0 : speeds[(index - 1) % speeds.count]
                let raw = UInt16(clamping: Int((speed * FireReport.speedScale).rounded()))
                let payload: [UInt8] = [
                    UInt8(index),
                    0x00, 0x00,
                    UInt8(raw & 0xFF), UInt8(raw >> 8),
                ]
                return [ChronoFrame(command: .logRecord, payload: payload).encode(keys: keys)]

            default:
                return []
            }
        }
    }
}
