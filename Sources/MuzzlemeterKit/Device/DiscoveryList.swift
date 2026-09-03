import Foundation

extension DiscoveredPeripheral {
    /// Signal strength reduced to a 0-4 bar count. 0 if there's no RSSI.
    ///
    /// Showing dBm directly doesn't convey "is -67 strong or weak?" The goal is to tell
    /// **which of several nearby devices is the one in hand**, so a relative sense of
    /// strength is enough — the absolute value doesn't matter.
    ///
    /// The thresholds are the common rules of thumb for BLE in practice: `>= -55` very
    /// close / `>= -67` good / `>= -80` usable / `>= -90` unstable / below that,
    /// effectively out of range.
    public var signalBars: Int {
        guard let rssi else { return 0 }
        if rssi >= -55 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 0
    }
}

/// The list of devices found while scanning.
///
/// Held by `ChronoDevice`, delivered as `ChronoEvent.discovered` only when it changes.
/// Since the same device's advertisement arrives many times per second, **not delivering
/// an event when nothing changed** is the whole point — delivering one every time would
/// rebuild the UI every second.
public struct DiscoveryList: Sendable, Hashable, Codable {
    /// The list in discovery order. Use `sorted` for the display order.
    public private(set) var peripherals: [DiscoveredPeripheral]
    /// "The device connected last time." Used to mark it in the list and place it first.
    public var rememberedID: UUID?

    public init(peripherals: [DiscoveredPeripheral] = [], rememberedID: UUID? = nil) {
        self.peripherals = peripherals
        self.rememberedID = rememberedID
    }

    public var isEmpty: Bool { peripherals.isEmpty }
    public var count: Int { peripherals.count }

    public func isRemembered(_ peripheral: DiscoveredPeripheral) -> Bool {
        rememberedID != nil && peripheral.id == rememberedID
    }

    /// Adds a device, or updates the info (RSSI / name) of one already present.
    ///
    /// - Returns: `true` if the list's contents changed. **`false` if nothing changed**,
    ///   so the caller can skip delivering an event.
    @discardableResult
    public mutating func upsert(_ peripheral: DiscoveredPeripheral) -> Bool {
        guard let index = peripherals.firstIndex(where: { $0.id == peripheral.id }) else {
            peripherals.append(peripheral)
            return true
        }
        guard peripherals[index] != peripheral else { return false }
        peripherals[index] = peripheral
        return true
    }

    public mutating func removeAll() {
        peripherals.removeAll()
    }

    /// The order shown on screen.
    ///
    /// 1. **The last-connected device goes on top** (so the usual one sits where it's
    ///    easiest to tap).
    /// 2. Then by signal strength (stronger likely means closer, i.e. more likely to be
    ///    in hand).
    /// 3. Then by name (a deterministic tiebreaker, so the order doesn't flicker on ties).
    public var sorted: [DiscoveredPeripheral] {
        peripherals.sorted { lhs, rhs in
            let lhsRemembered = isRemembered(lhs)
            let rhsRemembered = isRemembered(rhs)
            if lhsRemembered != rhsRemembered { return lhsRemembered }
            let lhsRSSI = lhs.rssi ?? Int.min
            let rhsRSSI = rhs.rssi ?? Int.min
            if lhsRSSI != rhsRSSI { return lhsRSSI > rhsRSSI }
            return lhs.displayName < rhs.displayName
        }
    }
}
