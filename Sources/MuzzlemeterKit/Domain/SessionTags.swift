import Foundation

/// セッションのタグ（「ホップ強め」「フィールド」など）を扱う純粋なロジック。
///
/// タグは `Session` では**改行区切りの 1 列**として持っている（別テーブルにするほどの
/// 数ではない）。文字列と配列の行き来、重複の潰しかた、検索の当てかたを 1 箇所に
/// 集めておかないと、保存側と絞り込み側で「同じタグ」の判定がずれる。
public enum SessionTags {
    /// 保存時の区切り。タグ自体に改行は入れられない。
    public static let separator = "\n"
    /// CSV に出すときの区切り。カンマは CSV の区切りと衝突するのでセミコロンにする。
    public static let csvSeparator = ";"

    /// 1 つのタグとして通す形に整える。前後の空白を落とし、改行は空白に潰す。
    public static func normalized(_ tag: String) -> String {
        tag.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 同じタグかどうかを判定するための鍵。
    ///
    /// 大文字小文字と全角半角を無視する。「HOP」と「hop」、「ﾌｨｰﾙﾄﾞ」と「フィールド」は
    /// 同じタグ。**濁点の違いは無視しない**（日本語では「ハス」と「バス」が別の語なので、
    /// 濁点まで潰すと違うタグが 1 つに混ざる）。
    ///
    /// 半角の「ﾞ」「ﾟ」は幅を揃えただけでは**結合しない印**（U+309B / U+309C）に
    /// なって前の文字とくっつかないので、結合用（U+3099 / U+309A）へ置き換えてから
    /// 合成する。これをしないと「ﾄﾞ」が「ト」＋印のままで「ド」と一致しない。
    public static func key(_ tag: String) -> String {
        let folded = normalized(tag).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return folded
            .replacingOccurrences(of: "\u{309B}", with: "\u{3099}")
            .replacingOccurrences(of: "\u{309C}", with: "\u{309A}")
            .precomposedStringWithCanonicalMapping
    }

    /// 保存された文字列をタグの配列にする。空要素と重複は落とす（**先に出たほうを残す**）。
    public static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.components(separatedBy: separator) {
            let tag = normalized(piece)
            guard !tag.isEmpty, seen.insert(key(tag)).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// 配列を保存用の 1 列に畳む。`parse` を通してから繋ぐので、往復しても増えない。
    public static func joined(_ tags: [String]) -> String {
        parse(tags.joined(separator: separator)).joined(separator: separator)
    }

    /// CSV の 1 セルに出す形（`ホップ強め;屋内`）。
    public static func csvField(_ tags: [String]) -> String {
        parse(tags.joined(separator: separator)).joined(separator: csvSeparator)
    }

    /// タグを足す。既にあるもの（表記ゆれ込み）は足さない。
    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        let candidate = normalized(tag)
        guard !candidate.isEmpty else { return tags }
        guard !tags.contains(where: { key($0) == key(candidate) }) else { return tags }
        return tags + [candidate]
    }

    /// タグを外す。表記ゆれも一致とみなす。
    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { key($0) != key(tag) }
    }

    public static func contains(_ tag: String, in tags: [String]) -> Bool {
        tags.contains { key($0) == key(tag) }
    }

    /// これまでに使われたタグを、**よく使う順 → 名前順**で並べる。
    ///
    /// 新しい順ではなく頻度順にするのは、候補として出したときに
    /// 「いつも付けているタグ」が上に来るほうが打鍵が減るため。
    public static func used(in tagLists: [[String]]) -> [String] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for tags in tagLists {
            for tag in tags {
                let k = key(tag)
                counts[k, default: 0] += 1
                if display[k] == nil { display[k] = normalized(tag) }
            }
        }
        return counts.keys
            .sorted { lhs, rhs in
                let (lc, rc) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
                if lc != rc { return lc > rc }
                return (display[lhs] ?? lhs) < (display[rhs] ?? rhs)
            }
            .compactMap { display[$0] }
    }

    /// 入力候補。**既に付いているものは出さない**（押しても何も起きない候補は邪魔）。
    ///
    /// - Parameters:
    ///   - existing: これまでに使ったタグ（`used(in:)` の結果）
    ///   - starters: 何も無いときのための既定の候補
    ///   - current: いま付いているタグ
    public static func suggestions(
        existing: [String],
        starters: [String],
        current: [String],
        limit: Int = 12
    ) -> [String] {
        var seen = Set(current.map(key))
        var result: [String] = []
        for tag in existing + starters {
            let k = key(tag)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            result.append(normalized(tag))
            if result.count >= limit { break }
        }
        return result
    }
}

/// 履歴の絞り込み条件。文字検索・タグ（AND）・銃の名前。
///
/// 述語を SwiftData に渡さず**取得済みの配列に対して**当てる前提の値。件数は
/// 高々数百で、タグは 1 列の文字列なので、`#Predicate` に落とすより読みやすく、
/// 何より**テストできる**。
public struct SessionFilter: Sendable, Equatable {
    /// タイトル・メモ・タグを横断する文字検索。
    public var searchText: String
    /// 選んだタグ。**全部付いているセッションだけ**を残す（AND）。
    public var tags: [String]
    /// 銃の名前（セッションに記録されたスナップショット）。`nil` は全部。
    public var gunName: String?

    public init(searchText: String = "", tags: [String] = [], gunName: String? = nil) {
        self.searchText = searchText
        self.tags = tags
        self.gunName = gunName
    }

    /// 何か絞り込んでいるか。UI の「解除」ボタンを出すかどうかに使う。
    public var isActive: Bool {
        !trimmedSearchText.isEmpty || !tags.isEmpty || gunName != nil
    }

    public var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// この条件に合うか。
    ///
    /// タグは **AND**（絞り込みは「条件を足すほど狭くなる」のが直感に合う）。
    /// 文字検索はタイトル・メモ・タグの**どれかに含まれれば通る**（OR）。
    public func matches(
        title: String,
        notes: String?,
        tags sessionTags: [String],
        gunName sessionGunName: String
    ) -> Bool {
        if let gunName, gunName != sessionGunName { return false }
        for tag in tags where !SessionTags.contains(tag, in: sessionTags) {
            return false
        }
        let needle = trimmedSearchText
        guard !needle.isEmpty else { return true }
        let haystacks = [title, notes ?? ""] + sessionTags
        let folded = SessionTags.key(needle)
        return haystacks.contains { SessionTags.key($0).contains(folded) }
    }

    /// 選んだタグを入れ替える（付いていれば外す）。
    public mutating func toggle(tag: String) {
        if SessionTags.contains(tag, in: tags) {
            tags = SessionTags.removing(tag, from: tags)
        } else {
            tags = SessionTags.adding(tag, to: tags)
        }
    }

    public mutating func clear() {
        searchText = ""
        tags = []
        gunName = nil
    }
}
