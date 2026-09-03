import Foundation

extension DiscoveredPeripheral {
    /// 電波強度を 0〜4 本のバーに落としたもの。RSSI が無ければ 0。
    ///
    /// dBm をそのまま出しても「−67 は強いのか弱いのか」が伝わらない。
    /// 目的は**複数台あるときにどれが手元の 1 台か**を見分けることなので、
    /// 絶対値ではなく相対的な強さが読めれば足りる。
    ///
    /// 区切りは BLE の実測でよく使われる目安:
    /// `≥ -55` 至近 / `≥ -67` 良好 / `≥ -80` 実用 / `≥ -90` 不安定 / それ未満 圏外に近い。
    public var signalBars: Int {
        guard let rssi else { return 0 }
        if rssi >= -55 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 0
    }
}

/// スキャンで見つかっている機器の一覧。
///
/// `ChronoDevice` が持ち、変化したときだけ `ChronoEvent.discovered` として流す。
/// 「同じ機器の広告が 1 秒に何本も届く」ので、**変化していないなら流さない**のが要点。
/// 流しっぱなしにすると UI が毎秒作り直される。
public struct DiscoveryList: Sendable, Hashable, Codable {
    /// 見つかった順の一覧。表示の並べ替えは `sorted` で行う。
    public private(set) var peripherals: [DiscoveredPeripheral]
    /// 「前回接続した機器」。一覧で目印を出し、先頭に並べるために使う。
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

    /// 追加、または既にある機器の情報（RSSI・名前）を更新する。
    ///
    /// - Returns: 一覧の中身が変わったなら `true`。**変わっていなければ `false`** で、
    ///   呼び出し側はイベントを流さずに済む。
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

    /// 画面に出す順。
    ///
    /// 1. **前回接続した機器を最上段**（いつもの 1 台をいちばん押しやすい位置に置く）
    /// 2. 電波の強い順（近い＝手元にある可能性が高い）
    /// 3. 名前順（同点のときに順番がちらつかないよう、決定的に並べる）
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
