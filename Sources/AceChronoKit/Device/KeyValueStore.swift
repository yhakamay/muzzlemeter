import Foundation

/// 小さな設定値の永続化。`ChronoDevice` が「最後に接続した機器」を覚えるために使う。
///
/// `UserDefaults` を直接触らずここを挟むのは、テストでプロセス全体の状態を汚さないため。
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

/// テスト・Preview 用のメモリ実装。
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

/// `UserDefaults` 実装。アプリ本体はこちらを使う。
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
