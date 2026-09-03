import Foundation

/// A device found while scanning.
public struct DiscoveredPeripheral: Sendable, Hashable, Identifiable, Codable {
    /// CoreBluetooth's `CBPeripheral.identifier` (a UUID stable only within this Mac /
    /// iPhone).
    public let id: UUID
    public let name: String?
    /// The received signal strength (dBm). `nil` if unknown.
    public let rssi: Int?
    /// The service UUIDs that were advertised.
    ///
    /// The AC6000 **doesn't advertise a service**, so this is always empty on real
    /// hardware.
    public let advertisedServices: [UUID]
    /// The advertisement's Manufacturer Specific Data (`00 05 08 c4 94 52 04`).
    ///
    /// The AC6000 carries the checksum key here (`DeviceKeys(manufacturerData:)`).
    /// **This is required for the handshake, so the transport must always carry it
    /// along.**
    public let manufacturerData: Data?

    public init(
        id: UUID,
        name: String?,
        rssi: Int? = nil,
        advertisedServices: [UUID] = [],
        manufacturerData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServices = advertisedServices
        self.manufacturerData = manufacturerData
    }

    public var displayName: String { name ?? id.uuidString }

    /// The checksum key extracted from the advertisement. `nil` if not present.
    public var keys: DeviceKeys? {
        manufacturerData.flatMap(DeviceKeys.init(manufacturerData:))
    }
}

/// A raw event from the transport layer (BLE itself), before protocol interpretation.
public enum TransportEvent: Sendable {
    case discovered(DiscoveredPeripheral)
    case connected(peripheral: UUID)
    case disconnected(peripheral: UUID, reason: String?)
    /// A value received via notify / indicate / read.
    case value(characteristic: UUID, data: Data)
    /// A subscription was established.
    case subscribed(characteristic: UUID)
    /// A recoverable error (e.g. a failed connection attempt). Fatal errors are returned
    /// via `throws` instead.
    case failed(reason: String)
}

public enum ChronoTransportError: Error, Sendable, Equatable {
    case notConnected
    case unavailable(String)
    case unknownCharacteristic(UUID)
    case writeNotSupported(UUID)
    /// A write to a forbidden characteristic (OTA control) was rejected. See
    /// `docs/PROTOCOL.md` §11.
    case forbiddenCharacteristic(UUID)
}

/// An abstraction that hides the actual BLE implementation.
///
/// Two implementations are expected:
/// - `CoreBluetoothTransport` (real hardware. The CoreBluetooth code in
///   `Sources/MuzzlemeterSniff/BLESniffer.swift` is moved here once it's wrapped in an
///   actor, since the delegate runs on a dedicated queue)
/// - `ReplayTransport` (plays back recorded packets. For the simulator, previews, and
///   tests)
///
/// Every method is `async` so an implementation can be an `actor`.
public protocol ChronoTransport: Sendable {
    /// The stream that delivers transport events. Assumed to have a **single consumer**
    /// (only `ChronoDevice` subscribes to it).
    var events: AsyncStream<TransportEvent> { get async }

    /// Starts scanning. No filtering is applied when `services` / `nameFilter` are `nil`.
    func scan(services: [UUID]?, nameFilter: String?) async throws
    func stopScan() async
    func connect(to peripheral: UUID) async throws
    func disconnect() async
    func subscribe(to characteristic: UUID) async throws
    func write(_ data: Data, to characteristic: UUID, withResponse: Bool) async throws
    /// Signals that subscription and initial writes have all finished.
    ///
    /// A no-op on real BLE (notify already started as of `subscribe`).
    /// `ReplayTransport` starts playback here. Having this means the race of "the first
    /// packet arrives before subscription has fully finished" can't structurally happen.
    func finishSetup() async
    /// Ends the event stream and releases internal resources. This instance can't be
    /// used afterward.
    func shutdown() async
}

extension ChronoTransport {
    public func finishSetup() async {}
}
