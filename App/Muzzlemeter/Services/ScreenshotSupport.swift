import Foundation

/// スクリーンショット・目視確認のための起動引数。**Debug ビルドのシミュレータでのみ効く。**
///
/// なぜ要るか: 規制上限の色分けや N 発モードのような機能は「特定の値が入っている状態」で
/// ないと見えない。実機を撃たずに、あるいはシミュレータを手で操作せずにその状態を作れないと、
/// 変更のたびに UI を目視確認する手間が現実的でなくなる。
///
/// リリースビルドでは全て `nil` / `false` を返す（引数の解釈すら行わない）ので、
/// 製品の挙動には一切関わらない。
///
/// ```sh
/// xcrun simctl launch <udid> com.yhakamay.muzzlemeter \
///   --replay-capture --demo-energy-limit 0.001 --demo-target-shots 10 \
///   --demo-tab sessions --demo-latest-session
/// ```
enum ScreenshotSupport {
    /// 選択中プロファイルの規制上限を上書きする（J）。
    static var energyLimitOverride: Double? { double(for: "--demo-energy-limit") }

    /// 選択中プロファイルの目標発数を上書きする。`0` で「手動」に戻す。
    static var targetShotCountOverride: Int? { int(for: "--demo-target-shots") }

    /// 起動時に開くタブ（`live` / `sessions` / `settings`）。
    static var initialTab: String? { value(for: "--demo-tab") }

    /// 起動直後に機器選択シートを開く。
    static var opensScanSheet: Bool { flag("--demo-scan-sheet") }

    /// 履歴タブで、いちばん新しいセッションの詳細を開く。
    static var opensLatestSession: Bool { flag("--demo-latest-session") }

    // MARK: - 引数の読み取り

    private static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static func value(for key: String) -> String? {
        guard isEnabled else { return nil }
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func flag(_ key: String) -> Bool {
        isEnabled && CommandLine.arguments.contains(key)
    }

    private static func double(for key: String) -> Double? { value(for: key).flatMap(Double.init) }
    private static func int(for key: String) -> Int? { value(for: key).flatMap(Int.init) }
}
