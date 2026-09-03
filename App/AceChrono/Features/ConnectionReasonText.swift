import Foundation

/// `ConnectionState.disconnected(reason:)` に入ってくる理由文字列を、表示言語に合わせて言い換える。
///
/// 理由を作っているのは `AceChronoKit`（`ChronoDevice` / `CoreBluetoothTransport`）で、
/// あちらは**実機で検証済みの BLE 層**だから触らない。またライブラリは macOS の
/// `acechrono-sniff` からも使われていて、そちらの出力は開発者向けの日本語のままでよい。
/// そこで「翻訳は表示側の仕事」と割り切り、既知の文言だけをここで置き換える。
///
/// 対応表に無い文字列（OS のエラー文など）はそのまま出す。**握りつぶさない。**
enum ConnectionReasonText {
    static func localized(_ raw: String) -> String {
        if let known = exact[raw] { return known }
        for (prefix, make) in prefixed where raw.hasPrefix(prefix) {
            return make(String(raw.dropFirst(prefix.count)))
        }
        return raw
    }

    /// 完全一致で置き換えるもの。
    private static var exact: [String: String] {
        [
            "本体の電源が切れました": String(localized: "本体の電源が切れました"),
            "Bluetooth がオフです": String(localized: "Bluetooth がオフです"),
            "Bluetooth の使用が許可されていません": String(localized: "Bluetooth の使用が許可されていません"),
            "この端末では Bluetooth Low Energy が使えません":
                String(localized: "この端末では Bluetooth Low Energy が使えません"),
            "必要なサービスが見つかりません": String(localized: "必要なサービスが見つかりません"),
            "鍵ハンドシェイク（0x4B）に応答がありません。本体の電源を入れ直すか、本体の電源ボタンを押してペアリングを許可してください。":
                String(localized: "鍵ハンドシェイク（0x4B）に応答がありません。本体の電源を入れ直すか、本体の電源ボタンを押してペアリングを許可してください。"),
        ]
    }

    /// 「<説明>: <詳細>」の形。詳細は OS が作ったエラー文なので、そのまま後ろに残す。
    private static var prefixed: [(String, (String) -> String)] {
        [
            ("スキャンを開始できません: ", { String(localized: "スキャンを開始できません: \($0)") }),
            ("購読に失敗しました: ", { String(localized: "購読に失敗しました: \($0)") }),
            ("ハンドシェイクを送信できません: ", { String(localized: "ハンドシェイクを送信できません: \($0)") }),
            ("接続に失敗しました: ", { String(localized: "接続に失敗しました: \($0)") }),
            ("サービス探索に失敗: ", { String(localized: "サービス探索に失敗: \($0)") }),
            ("値の受信に失敗: ", { String(localized: "値の受信に失敗: \($0)") }),
            ("購読に失敗: ", { String(localized: "購読に失敗: \($0)") }),
            ("書き込みに失敗: ", { String(localized: "書き込みに失敗: \($0)") }),
        ]
    }
}
