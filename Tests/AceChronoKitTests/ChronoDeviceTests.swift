import Foundation
import Testing
@testable import AceChronoKit

/// テスト用のデコーダ。4 バイト `[speed_lo, speed_hi, rps_lo, rps_hi]`（いずれも
/// リトルエンディアン UInt16、×100 スケール、rps = 0 は「報告なし」）をショットとして読む。
/// 実機のパケット形式が未確定のため、これは**あくまでテスト用の取り決め**。
struct FakeShotDecoder: ChronoPacketDecoder {
    let timestamps: [Date]

    init(timestamps: [Date] = []) {
        self.timestamps = timestamps
    }

    func decode(characteristic: UUID, data: Data) -> [ChronoEvent] {
        guard data.count == 4 else { return [.raw(characteristic: characteristic, data: data)] }
        let bytes = [UInt8](data)
        let rawSpeed = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let rawRev = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let shot = Shot(
            velocityMetersPerSecond: Double(rawSpeed) / 100.0,
            rateOfFireRPS: rawRev == 0 ? nil : Double(rawRev) / 100.0
        )
        return [.shot(shot)]
    }
}

@Suite("ChronoDevice")
struct ChronoDeviceTests {
    private let ffe1 = BluetoothUUID.short(0xFFE1)

    /// 91.20 m/s / 92.50 m/s / 93.00 m/s (ROF 12.50 rps)
    private func makeScript() throws -> ReplayScript {
        try ReplayScript.parse(
            """
            +0    FFE1 a0 23 00 00
            +100  FFE1 22 24 00 00
            +200  FFE1 54 24 e2 04
            """
        )
    }

    private func makeDevice(store: any KeyValueStore = InMemoryKeyValueStore())
        async throws -> (ChronoDevice, ReplayTransport)
    {
        let transport = ReplayTransport(script: try makeScript(), speed: 0)
        let device = ChronoDevice(
            transport: transport,
            decoder: FakeShotDecoder(),
            store: store,
            configuration: .init(
                notifyCharacteristics: [ffe1],
                autoReconnect: false
            )
        )
        return (device, transport)
    }

    @Test("scan → connect → subscribe が自動で進み、ショットが配信される")
    func endToEndReplay() async throws {
        let (device, transport) = try await makeDevice()
        let events = device.events
        await device.start()

        var shots = [Shot]()
        var states = [ConnectionState]()
        for await event in events {
            switch event {
            case .shot(let shot):
                shots.append(shot)
                if shots.count == 3 { await device.shutdown() }
            case .connectionState(let state):
                states.append(state)
            default:
                continue
            }
        }
        _ = transport

        #expect(shots.count == 3)
        #expect(abs(shots[0].velocityMetersPerSecond - 91.20) < 1e-9)
        #expect(abs(shots[1].velocityMetersPerSecond - 92.50) < 1e-9)
        #expect(abs(shots[2].velocityMetersPerSecond - 93.00) < 1e-9)
        #expect(shots[0].rateOfFireRPS == nil)
        #expect(shots[2].rateOfFireRPS.map { abs($0 - 12.50) < 1e-9 } == true)

        // 状態は scanning → connecting → pairing → ready の順に流れる。
        #expect(states.prefix(4) == [.scanning, .connecting, .pairing, .ready])
    }

    @Test("接続した機器は KeyValueStore に記録され、forgetDevice で消える")
    func remembersLastPeripheral() async throws {
        let store = InMemoryKeyValueStore()
        let (device, _) = try await makeDevice(store: store)
        let events = device.events
        await device.start()

        for await event in events {
            if case .connectionState(.ready) = event { break }
        }

        let remembered = await device.rememberedPeripheral
        #expect(remembered == ReplayTransport.demoPeripheral.id)
        #expect(store.string(forKey: ChronoDevice.lastPeripheralKey) != nil)

        await device.forgetDevice()
        let forgotten = await device.rememberedPeripheral
        #expect(forgotten == nil)
        await device.shutdown()
    }

    @Test("PassthroughDecoder は解釈せず .raw を流す")
    func passthroughDecoderEmitsRaw() async throws {
        let transport = ReplayTransport(script: try makeScript(), speed: 0)
        let device = ChronoDevice(
            transport: transport,
            decoder: PassthroughDecoder(),
            configuration: .init(notifyCharacteristics: [ffe1], autoReconnect: false)
        )
        let events = device.events
        await device.start()

        var raws = [Data]()
        for await event in events {
            if case .raw(let characteristic, let data) = event {
                #expect(characteristic == ffe1)
                raws.append(data)
                if raws.count == 3 { await device.shutdown() }
            }
        }
        #expect(raws.count == 3)
        #expect(raws[0] == Data([0xA0, 0x23, 0x00, 0x00]))
    }

    @Test("autoReconnect は切り替えられる")
    func autoReconnectToggle() async throws {
        let (device, _) = try await makeDevice()
        #expect(await device.autoReconnect == false)
        await device.setAutoReconnect(true)
        #expect(await device.autoReconnect == true)
        await device.shutdown()
    }
}
