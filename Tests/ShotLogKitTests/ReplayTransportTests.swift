import Foundation
import Testing
@testable import ShotLogKit

@Suite("ReplayTransport")
struct ReplayTransportTests {
    private let ffe1 = BluetoothUUID.short(0xFFE1)
    private let ffe2 = BluetoothUUID.short(0xFFE2)

    private func makeScript() throws -> ReplayScript {
        try ReplayScript.parse(
            """
            +0    FFE1 01
            +100  FFE1 02
            +200  FFE2 aa
            +300  FFE1 03
            """
        )
    }

    /// `speed = 0` なら実時間を待たずに全パケットが順番どおり流れる。
    @Test("speed=0 で順序どおり再生される")
    func replaysInOrder() async throws {
        let transport = ReplayTransport(script: try makeScript(), speed: 0)
        let events = await transport.events

        try await transport.scan(services: nil, nameFilter: nil)
        try await transport.connect(to: ReplayTransport.demoPeripheral.id)
        try await transport.subscribe(to: ffe1)
        try await transport.subscribe(to: ffe2)
        await transport.finishSetup()

        var received = [Data]()
        for await event in events {
            switch event {
            case .value(_, let data):
                received.append(data)
                if received.count == 4 { await transport.shutdown() }
            default:
                continue
            }
        }
        #expect(received == [Data([0x01]), Data([0x02]), Data([0xAA]), Data([0x03])])
    }

    @Test("購読していない characteristic のパケットは流れない")
    func filtersUnsubscribedCharacteristics() async throws {
        let transport = ReplayTransport(script: try makeScript(), speed: 0)
        let events = await transport.events

        try await transport.connect(to: ReplayTransport.demoPeripheral.id)
        try await transport.subscribe(to: ffe2)
        await transport.finishSetup()

        var received = [UUID]()
        for await event in events {
            if case .value(let characteristic, _) = event {
                received.append(characteristic)
                await transport.shutdown()
            }
        }
        #expect(received == [ffe2])
    }

    @Test("scan で機器が 1 台見つかる。名前フィルタも効く")
    func scanEmitsPeripheral() async throws {
        let transport = ReplayTransport(script: try makeScript(), speed: 0)
        let events = await transport.events

        try await transport.scan(services: nil, nameFilter: "存在しない名前")
        try await transport.scan(services: nil, nameFilter: "AC6000")
        await transport.shutdown()

        var discovered = [DiscoveredPeripheral]()
        for await event in events {
            if case .discovered(let peripheral) = event { discovered.append(peripheral) }
        }
        #expect(discovered.count == 1)
        #expect(discovered.first?.name == "AC6000BT-DEMO")
    }

    @Test("未接続では subscribe / write が失敗する")
    func requiresConnection() async throws {
        let transport = ReplayTransport(script: try makeScript(), speed: 0)
        await #expect(throws: ChronoTransportError.notConnected) {
            try await transport.subscribe(to: ffe1)
        }
        await #expect(throws: ChronoTransportError.notConnected) {
            try await transport.write(Data([0x01]), to: ffe1, withResponse: true)
        }
        await transport.shutdown()
    }

    @Test("write は記録される（初期化コマンドの検証用）")
    func recordsWrites() async throws {
        let transport = ReplayTransport(script: try makeScript(), speed: 0)
        try await transport.connect(to: ReplayTransport.demoPeripheral.id)
        try await transport.write(Data([0x4B]), to: ffe1, withResponse: true)
        let writes = await transport.writes
        #expect(writes.count == 1)
        #expect(writes.first?.data == Data([0x4B]))
        #expect(writes.first?.withResponse == true)
        await transport.shutdown()
    }
}
