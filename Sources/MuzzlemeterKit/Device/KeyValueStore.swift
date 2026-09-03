import Foundation

/// Persistence for small settings values. Used by `ChronoDevice` to remember "the last
/// device connected."
///
/// This sits in front of `UserDefaults` rather than touching it directly, so tests don't
/// pollute process-wide state.
public protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

extension KeyValueStore {
    public func uuid(forKey key: String) -> UUID? {
        string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    public func set(_ value: UUID?, forKey key: String) {
        set(value?.uuidString, forKey: key)
    }
}

/// An in-memory implementation for tests and previews.
public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var storage: [String: String]
    private let lock = NSLock()

    public init(_ initial: [String: String] = [:]) {
        self.storage = initial
    }

    public func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}

/// The `UserDefaults`-backed implementation. Used by the app itself.
public struct UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
