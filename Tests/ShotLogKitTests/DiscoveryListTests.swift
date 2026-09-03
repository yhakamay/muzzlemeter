import Foundation
import Testing
@testable import ShotLogKit

@Suite("DiscoveryList（スキャン一覧）")
struct DiscoveryListTests {
    private func peripheral(
        _ name: String,
        rssi: Int?,
        id: UUID = UUID()
    ) -> DiscoveredPeripheral {
        DiscoveredPeripheral(id: id, name: name, rssi: rssi)
    }

    @Test("RSSI をバー 0〜4 本に落とす")
    func signalBars() {
        #expect(peripheral("a", rssi: -40).signalBars == 4)
        #expect(peripheral("a", rssi: -55).signalBars == 4)
        #expect(peripheral("a", rssi: -60).signalBars == 3)
        #expect(peripheral("a", rssi: -70).signalBars == 2)
        #expect(peripheral("a", rssi: -85).signalBars == 1)
        #expect(peripheral("a", rssi: -100).signalBars == 0)
        // RSSI が取れないときも 0 本（「不明」を強い電波に見せない）。
        #expect(peripheral("a", rssi: nil).signalBars == 0)
    }

    @Test("初めての機器は追加され、変化ありと答える")
    func upsertNew() {
        var list = DiscoveryList()
        // `#expect` の中では `list` が不変として捕まるので、呼び出しは外で行う。
        let changed = list.upsert(peripheral("AC6000BT-A", rssi: -60))
        #expect(changed)
        #expect(list.count == 1)
    }

    @Test("同じ広告が続いても変化なしと答える（UI を作り直させない）")
    func upsertUnchanged() {
        let id = UUID()
        var list = DiscoveryList()
        let found = peripheral("AC6000BT-A", rssi: -60, id: id)
        let first = list.upsert(found)
        let second = list.upsert(found)
        #expect(first)
        #expect(!second)
        #expect(list.count == 1)
    }

    @Test("RSSI が動いたら上書きして最新にする")
    func upsertUpdatesRSSI() {
        let id = UUID()
        var list = DiscoveryList()
        list.upsert(peripheral("AC6000BT-A", rssi: -80, id: id))
        let changed = list.upsert(peripheral("AC6000BT-A", rssi: -50, id: id))
        #expect(changed)
        #expect(list.count == 1)
        #expect(list.peripherals.first?.rssi == -50)
        #expect(list.peripherals.first?.signalBars == 4)
    }

    @Test("前回接続した機器が最上段、あとは電波の強い順")
    func sortOrder() {
        let remembered = UUID()
        var list = DiscoveryList(rememberedID: remembered)
        list.upsert(peripheral("AC6000BT-STRONG", rssi: -45))
        list.upsert(peripheral("AC6000BT-WEAK", rssi: -88))
        // 前回の機器はいちばん弱いが、それでも先頭に来る。
        list.upsert(peripheral("AC6000BT-MINE", rssi: -92, id: remembered))

        let names = list.sorted.map(\.displayName)
        #expect(names == ["AC6000BT-MINE", "AC6000BT-STRONG", "AC6000BT-WEAK"])
        let first = try! #require(list.sorted.first)
        #expect(list.isRemembered(first))
    }

    @Test("RSSI が同点なら名前順（並びがちらつかない）")
    func stableOrderOnTie() {
        var list = DiscoveryList()
        list.upsert(peripheral("AC6000BT-B", rssi: -60))
        list.upsert(peripheral("AC6000BT-A", rssi: -60))
        #expect(list.sorted.map(\.displayName) == ["AC6000BT-A", "AC6000BT-B"])
    }

    @Test("RSSI 不明の機器は最後に回す")
    func unknownRSSILast() {
        var list = DiscoveryList()
        list.upsert(peripheral("AC6000BT-UNKNOWN", rssi: nil))
        list.upsert(peripheral("AC6000BT-WEAK", rssi: -95))
        #expect(list.sorted.map(\.displayName) == ["AC6000BT-WEAK", "AC6000BT-UNKNOWN"])
    }

    @Test("覚えている機器が無ければ目印は付かない")
    func noRememberedMark() {
        var list = DiscoveryList()
        let found = peripheral("AC6000BT-A", rssi: -60)
        list.upsert(found)
        let isRemembered = list.isRemembered(found)
        #expect(!isRemembered)
    }

    @Test("スキャンをやり直すと空になる")
    func removeAll() {
        var list = DiscoveryList()
        list.upsert(peripheral("AC6000BT-A", rssi: -60))
        list.removeAll()
        #expect(list.isEmpty)
    }
}

@Suite("ChronoDevice（スキャン一覧の配信）")
struct ChronoDeviceDiscoveryTests {
    @Test("見つけた機器が .discovered として流れ、前回接続の印が付く")
    func yieldsDiscoveryList() async {
        let store = InMemoryKeyValueStore()
        let demo = ReplayTransport.demoPeripheral
        // 「前回この機器に接続した」状態を作っておく。
        store.set(demo.id, forKey: ChronoDevice.lastPeripheralKey)

        let device = ChronoDevice(
            transport: ReplayTransport(script: ReplayScript(entries: []), speed: 0),
            store: store,
            configuration: ChronoDevice.Configuration(nameFilter: "AC6000BT-")
        )
        let events = device.events
        await device.start()

        var lists = [DiscoveryList]()
        for await event in events {
            if case .discovered(let list) = event {
                lists.append(list)
                if !list.isEmpty { break }
            }
        }
        let list = try! #require(lists.last)
        #expect(list.count == 1)
        #expect(list.peripherals.first?.name == "AC6000BT-DEMO")
        #expect(list.rememberedID == demo.id)
        let first = try! #require(list.peripherals.first)
        #expect(list.isRemembered(first))
        await device.shutdown()
    }
}
