import Foundation
import Testing
@testable import AceChronoKit

/// 実キャプチャを `ReplayTransport` で流し、実デコーダ + 実ハンドシェイクを通す
/// エンドツーエンドのテスト。
///
/// `ReplayTransport.demoPeripheral` は**実機の広告 manufacturer data をそのまま**
/// 持っているので、鍵 `c4/94` の解決から checksum 検証まで本番と同じ経路が走る。
@Suite("ハンドシェイク（実キャプチャ再生）")
struct ChronoHandshakeTests {
    private let notify = ChronoUUIDs.notifyCharacteristic
    private let write = ChronoUUIDs.writeCharacteristic

    private func makeDevice(
        store: any KeyValueStore = InMemoryKeyValueStore(),
        script: ReplayScript
    ) -> (ChronoDevice, ReplayTransport) {
        let transport = ReplayTransport(script: script, speed: 0)
        let device = ChronoDevice(
            transport: transport,
            decoder: AceChronoDecoder(),
            store: store,
            configuration: .ac6000(
                autoReconnect: false,
                handshake: .init(
                    initialDelay: 0,
                    ackTimeout: 2.0,
                    retryCount: 1,
                    commandGap: 0,
                    readsCurrentAmmo: true,
                    readsBattery: false
                )
            )
        )
        return (device, transport)
    }

    @Test("キャプチャ再生で ACK を受けて .ready に至り、5 発が配信される")
    func endToEnd() async throws {
        let store = InMemoryKeyValueStore()
        let (device, transport) = makeDevice(store: store, script: try Fixtures.script("acesoft-iphone-rx"))
        let events = device.events
        await device.start()

        var shots = [Shot]()
        var states = [ConnectionState]()
        var sawPowerOff = false
        for await event in events {
            switch event {
            case .shot(let shot):
                shots.append(shot)
            case .connectionState(let state):
                states.append(state)
            case .powerOff:
                sawPowerOff = true
            default:
                break
            }
            if shots.count == 5, states.contains(.ready) {
                await device.shutdown()
            }
        }

        #expect(shots.count == 5)
        #expect(states.contains(.ready))
        #expect(states.prefix(3) == [.scanning, .connecting, .pairing])
        let velocities = shots.map { ($0.velocityMetersPerSecond * 100).rounded() }
        #expect(velocities == [282, 250, 267, 266, 305])
        #expect(sawPowerOff)

        // 鍵は広告から解決され、成立後に永続化されている。
        let keys = await device.keys
        #expect(keys == Fixtures.keys)
        let stored = store.string(forKey: ChronoDevice.keysKey(for: ReplayTransport.demoPeripheral.id))
        #expect(stored == "c494")

        // 送信されたのは実キャプチャと同じバイト列。
        let writes = await transport.writes
        #expect(writes.first?.data == Data([0xAA, 0x06, 0x4B, 0xC4, 0x94, 0x53]))
        #expect(writes.first?.characteristic == write)
        #expect(writes.first?.withResponse == true)
        #expect(writes.contains { $0.data == Data([0xAA, 0x05, 0x5A, 0x00, 0x61]) })
        // CLEAR_LOG (0x61) や設定書き込みは絶対に送らない。
        #expect(!writes.contains { $0.data.count > 2 && $0.data[2] == 0x61 })
    }

    @Test("広告が無くても、保存済みの鍵でハンドシェイクできる")
    func fallsBackToStoredKeys() async throws {
        // manufacturer data を持たないペリフェラルで再生する。
        let peripheral = DiscoveredPeripheral(
            id: UUID(uuidString: "00000000-0000-0000-0000-ACEC40000001") ?? UUID(),
            name: "AC6000BT-NOADV",
            manufacturerData: nil
        )
        let store = InMemoryKeyValueStore([
            ChronoDevice.keysKey(for: peripheral.id): "c494"
        ])
        let transport = ReplayTransport(
            script: try Fixtures.script("acesoft-iphone-rx"),
            speed: 0,
            peripheral: peripheral
        )
        let device = ChronoDevice(
            transport: transport,
            decoder: AceChronoDecoder(),
            store: store,
            configuration: .ac6000(
                autoReconnect: false,
                handshake: .init(initialDelay: 0, ackTimeout: 2.0, retryCount: 0, commandGap: 0)
            )
        )
        let events = device.events
        await device.start()
        for await event in events {
            if case .connectionState(.ready) = event { await device.shutdown() }
        }

        let writes = await transport.writes
        #expect(writes.first?.data == Data([0xAA, 0x06, 0x4B, 0xC4, 0x94, 0x53]))
        #expect(await device.keys == Fixtures.keys)
    }

    @Test("ACK が来なければ再送し、それでも来なければ理由付きで切断する")
    func handshakeTimeout() async throws {
        // ACK を含まないスクリプト（FIRE_REPORT だけ）。
        let script = try ReplayScript.parse(
            "+0 3337E46E-F79E-4FF5-9A49-77C36D170C62 aa 0a 52 00 00 1a 01 00 00 79"
        )
        let transport = ReplayTransport(script: script, speed: 0)
        let device = ChronoDevice(
            transport: transport,
            decoder: AceChronoDecoder(),
            configuration: .ac6000(
                autoReconnect: false,
                handshake: .init(initialDelay: 0, ackTimeout: 0.05, retryCount: 1, commandGap: 0)
            )
        )
        let events = device.events
        await device.start()

        var reason: String?
        for await event in events {
            if case .connectionState(.disconnected(let text)) = event, let text {
                reason = text
                await device.shutdown()
            }
        }

        #expect(reason?.contains("0x4B") == true)
        // 初回 + 再送 1 回 = 2 本だけ送られている（それ以上の再送はしない）。
        let writes = await transport.writes
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0.data == Data([0xAA, 0x06, 0x4B, 0xC4, 0x94, 0x53]) })
    }

    @Test("forgetDevice は保存した鍵も一緒に消す")
    func forgetDeviceClearsKeys() async throws {
        let store = InMemoryKeyValueStore()
        let (device, _) = makeDevice(store: store, script: try Fixtures.script("acesoft-iphone-rx"))
        let events = device.events
        await device.start()
        for await event in events {
            if case .connectionState(.ready) = event { break }
        }
        #expect(store.string(forKey: ChronoDevice.keysKey(for: ReplayTransport.demoPeripheral.id)) != nil)

        await device.forgetDevice()
        #expect(store.string(forKey: ChronoDevice.keysKey(for: ReplayTransport.demoPeripheral.id)) == nil)
        #expect(store.string(forKey: ChronoDevice.lastPeripheralKey) == nil)
        await device.shutdown()
    }
}
