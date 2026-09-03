import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("ReplayScript")
struct ReplayScriptTests {
    private let ffe1 = BluetoothUUID.short(0xFFE1)
    private let ffe2 = BluetoothUUID.short(0xFFE2)

    @Test("16bit 短縮 UUID は Bluetooth Base UUID に展開される")
    func shortUUIDExpansion() {
        #expect(BluetoothUUID.parse("FFE1")?.uuidString == "0000FFE1-0000-1000-8000-00805F9B34FB")
        #expect(BluetoothUUID.parse("ffe1") == ffe1)
        #expect(BluetoothUUID.displayString(ffe1) == "FFE1")
        #expect(BluetoothUUID.parse("zzzz") == nil)
    }

    @Test("簡易形式: +<ms> <uuid> <hex>")
    func simpleFormat() throws {
        let script = try ReplayScript.parse(
            """
            # コメント行は無視される

            +0     FFE1  a0 23 00 00
            +1500  FFE1  b4230000
            +2000  ffe2  01
            """
        )
        #expect(script.entries.count == 3)
        #expect(script.entries[0].offsetSeconds == 0)
        #expect(script.entries[0].characteristic == ffe1)
        #expect(script.entries[0].data == Data([0xA0, 0x23, 0x00, 0x00]))
        #expect(script.entries[1].offsetSeconds == 1.5)
        #expect(script.entries[1].data == Data([0xB4, 0x23, 0x00, 0x00]))
        #expect(script.entries[2].characteristic == ffe2)
        #expect(script.duration == 2.0)
        #expect(script.characteristics == [ffe1, ffe2])
    }

    @Test("簡易形式の壊れた行はエラーになる")
    func simpleFormatErrors() {
        #expect(throws: ReplayScriptError.self) {
            _ = try ReplayScript.parse("+abc FFE1 00")
        }
        #expect(throws: ReplayScriptError.self) {
            _ = try ReplayScript.parse("+0 ZZZZ 00")
        }
        #expect(throws: ReplayScriptError.self) {
            _ = try ReplayScript.parse("+0 FFE1 xyz")
        }
        #expect(throws: ReplayScriptError.self) {
            _ = try ReplayScript.parse("+0 FFE1")
        }
    }

    @Test("sniffer ログ形式: ISO8601 タイムスタンプの差をオフセットにする")
    func snifferFormat() throws {
        let script = try ReplayScript.parse(
            """
            接続しました: AC6000BT-1234 [1A2B3C4D-0000-0000-0000-000000000000]

            === GATT ツリー ===
            service FFE0 (primary)
              └─ char FFE1  [read,notify]
            read FFE1 len=2 hex: 00 01 ascii: ..
            [2026-09-02T22:31:04.000+09:00] write -> FFE1 (withResponse) len=2 hex: 01 a5
            [2026-09-02T22:31:04.512+09:00] [+---- ms] FFE1 len=4 hex: a0 23 00 00 ascii: .#..
            [2026-09-02T22:31:05.512+09:00] [+1000.0 ms] FFE1 len=4 hex: b4 23 00 00 ascii: .#..
            [2026-09-02T22:31:05.762+09:00] [+250.0 ms] FFE2 len=1 hex: 5b ascii: [
            """
        )
        #expect(script.entries.count == 3)
        #expect(script.entries[0].offsetSeconds == 0)
        #expect(script.entries[0].data == Data([0xA0, 0x23, 0x00, 0x00]))
        #expect(abs(script.entries[1].offsetSeconds - 1.0) < 1e-6)
        #expect(abs(script.entries[2].offsetSeconds - 1.25) < 1e-6)
        #expect(script.entries[2].characteristic == ffe2)
        #expect(script.entries[2].data == Data([0x5B]))
    }

    @Test("sniffer ログ: タイムスタンプが読めない行では [+N ms] の差分を積み上げる")
    func snifferFormatDeltaFallback() throws {
        let script = try ReplayScript.parse(
            """
            [2026-09-02T22:31:04.512+09:00] [+---- ms] FFE1 len=1 hex: 01 ascii: .
            [???] [+250.0 ms] FFE1 len=1 hex: 02 ascii: .
            [???] [+250.0 ms] FFE1 len=1 hex: 03 ascii: .
            """
        )
        #expect(script.entries.count == 3)
        #expect(abs(script.entries[1].offsetSeconds - 0.25) < 1e-9)
        #expect(abs(script.entries[2].offsetSeconds - 0.50) < 1e-9)
    }

    @Test("両形式が同じスクリプトになる")
    func formatsAgree() throws {
        let simple = try ReplayScript.parse(
            """
            +0 FFE1 a0 23
            +1000 FFE1 b4 23
            """
        )
        let sniffed = try ReplayScript.parse(
            """
            [2026-09-02T22:31:04.000+09:00] [+---- ms] FFE1 len=2 hex: a0 23 ascii: .#
            [2026-09-02T22:31:05.000+09:00] [+1000.0 ms] FFE1 len=2 hex: b4 23 ascii: .#
            """
        )
        #expect(simple == sniffed)
    }

    @Test("serialized() は簡易形式に戻せる")
    func roundTrip() throws {
        let original = try ReplayScript.parse("+0 FFE1 a0 23\n+1500 FFE2 01 02 03")
        let reparsed = try ReplayScript.parse(original.serialized())
        #expect(original == reparsed)
    }

    @Test("エントリはオフセット順に並べ替えられる")
    func sortsEntries() throws {
        let script = try ReplayScript.parse("+500 FFE1 02\n+100 FFE1 01")
        #expect(script.entries.map(\.offsetSeconds) == [0.1, 0.5])
    }
}
