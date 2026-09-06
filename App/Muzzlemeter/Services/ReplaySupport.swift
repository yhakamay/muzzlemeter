import MuzzlemeterKit
import Foundation

/// **開発用**の再生ソース（起動引数と、Debug ビルドのシミュレータ）。
///
/// 利用者が自分で入れる「デモモード」は別物で、`ChronoService.isDemoMode` が持つ。
/// こちらは目視確認とスクリーンショット撮影のための仕掛けで、`ScreenshotSupport` の
/// 起動引数と対で使う。
///
/// **デモ専用のエンコーディングはもう存在しない。** 流すバイト列は実プロトコル
/// （`docs/PROTOCOL.md`）そのもので、`MuzzlemeterDecoder` が実機と同じように復号する。
/// 鍵ハンドシェイクも `ReplayTransport.demoPeripheral` が実機の広告
/// （`00 05 08 c4 94 52 04`）を持っているので同じ経路で成立する。
enum ReplaySupport {
    enum Source {
        /// 実キャプチャ（`acesoft-iphone-rx.txt`）。本物の 5 発が流れる。
        case capture
        /// UI 作り込み用に合成した射撃列。**バイト列は実プロトコルで組む。**
        case synthetic
    }

    /// `--replay` 起動、または **Debug の**シミュレータで動かしているか。
    ///
    /// シミュレータには CoreBluetooth のハードウェアが無いので、以前は
    /// **構成に関係なく**常に再生していた。デモモードが製品機能になったので、
    /// 暗黙の再生は Debug に限る。Release のシミュレータでは実機と同じく
    /// 「まだ何にも繋がっていない」状態から始まり、Live 画面のデモの案内と
    /// 設定のデモモードが、実機を持っていない人が見るのと同じ順序で確認できる。
    /// `ScreenshotSupport` の起動引数はもともと Debug のシミュレータ限定なので、
    /// 既存の目視確認・スクリーンショットの手順は何も変わらない。
    static var isEnabled: Bool {
        if CommandLine.arguments.contains("--replay") { return true }
        if CommandLine.arguments.contains("--replay-capture") { return true }
        #if DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// 既定は合成スクリプト（発数が多く UI を作りやすい）。
    /// `--replay-capture` を付けると実キャプチャを等倍で再生する。
    static var source: Source {
        CommandLine.arguments.contains("--replay-capture") ? .capture : .synthetic
    }

    static func makeTransport() -> ReplayTransport {
        switch source {
        case .capture:
            // 実キャプチャは 103 秒あり、最初の射撃が +50 秒。等倍だと待たされるので早送りする。
            ReplayTransport(
                script: withoutRecordedLogCount(captureScript()),
                speed: 6.0,
                repeats: true,
                loopGap: 3.0,
                responder: deviceLogResponder
            )
        case .synthetic:
            ReplayTransport(
                script: syntheticScript,
                speed: 1.0,
                repeats: true,
                loopGap: 4.0,
                responder: deviceLogResponder
            )
        }
    }

    /// 擬似本体の「本体内ログ」。
    ///
    /// 記録済みパケットを流すだけでは、**要求と応答の往復**（`0x62` → `0x63`）が
    /// 成り立たない。ログの取り込みはその往復そのものなので、再生でも答える
    /// 擬似ファームウェアを差しておく。件数の既定は実キャプチャの `0x62` が
    /// 答えていた 1 件で、`--demo-device-log N` で増やせる。
    ///
    /// **返すレコードの中身は推定**（`docs/PROTOCOL.md` §6.6）。実機の形式が
    /// 判明したら `ReplayTransport.deviceLogResponder` ごと差し替える。
    private static var deviceLogResponder: ReplayTransport.Responder {
        ReplayTransport.deviceLogResponder(
            count: ScreenshotSupport.deviceLogCountOverride ?? 1,
            keys: keys,
            brokenIndex: ScreenshotSupport.deviceLogBrokenIndex
        )
    }

    /// 記録済みの `0x62`（件数）応答をスクリプトから抜く。
    ///
    /// 擬似本体（`deviceLogResponder`）が `0x62` に答えるようになったので、
    /// **同じ擬似本体が 2 つの件数を言う**状態になっていた。キャプチャに写っている
    /// 応答（1 件）が遅れて流れると、`--demo-device-log 12` で作った状態を
    /// 上書きしてしまう。要求への応答は擬似ファームウェア側に一本化する。
    private static func withoutRecordedLogCount(_ script: ReplayScript) -> ReplayScript {
        ReplayScript(
            entries: script.entries.filter { entry in
                let bytes = [UInt8](entry.data)
                guard bytes.count >= 3, bytes[0] == ChronoFrame.header else { return true }
                return bytes[2] != ChronoCommand.logCount.rawValue
            }
        )
    }

    /// バンドルした実キャプチャ。読めなければ合成スクリプトにフォールバックする。
    static func captureScript() -> ReplayScript {
        if let url = Bundle.main.url(forResource: "acesoft-iphone-rx", withExtension: "txt"),
           let loaded = try? ReplayScript.load(contentsOf: url),
           !loaded.entries.isEmpty {
            return loaded
        }
        return syntheticScript
    }

    // MARK: - 合成スクリプト

    private static let keys = DemoScript.keys

    /// 単発 6 発 → フルオート 12 発。中身は `MuzzlemeterKit.DemoScript` にある。
    ///
    /// 利用者向けのデモモードと**同じ射撃列**を使う。開発用の再生とデモモードで
    /// 流れる弾速が違うと、目視確認で見ている画面が製品のデモと別物になる。
    static var syntheticScript: ReplayScript { DemoScript.script(keys: keys) }
}
