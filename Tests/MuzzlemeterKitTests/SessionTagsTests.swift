import Foundation
import Testing
@testable import MuzzlemeterKit

@Suite("SessionTags")
struct SessionTagsTests {
    @Test("改行区切りを配列にし、空要素と前後の空白を落とす")
    func parseTrimsAndDropsEmpty() {
        #expect(SessionTags.parse("ホップ強め\n  屋内  \n\n") == ["ホップ強め", "屋内"])
        #expect(SessionTags.parse("").isEmpty)
        #expect(SessionTags.parse("   \n  ").isEmpty)
    }

    @Test("重複は先に出たほうを残す")
    func parseDropsDuplicates() {
        #expect(SessionTags.parse("屋内\n屋内\nフィールド") == ["屋内", "フィールド"])
    }

    @Test("大文字小文字と全角半角の違いは同じタグとみなす")
    func keyFolding() {
        #expect(SessionTags.key("HOP") == SessionTags.key("hop"))
        #expect(SessionTags.key("ﾌｨｰﾙﾄﾞ") == SessionTags.key("フィールド"))
        #expect(SessionTags.key("Ｍ４") == SessionTags.key("M4"))
        #expect(SessionTags.parse("HOP\nhop") == ["HOP"])
    }

    @Test("濁点の違いは別のタグ（日本語では意味が変わる）")
    func voicedMarksAreSignificant() {
        #expect(SessionTags.key("ハス") != SessionTags.key("バス"))
        #expect(SessionTags.parse("ハス\nバス") == ["ハス", "バス"])
    }

    @Test("配列と文字列を往復してもタグは増えない")
    func roundTrip() {
        let tags = ["ホップ強め", "屋内"]
        #expect(SessionTags.parse(SessionTags.joined(tags)) == tags)
        #expect(SessionTags.joined(SessionTags.parse(SessionTags.joined(tags))) == SessionTags.joined(tags))
    }

    @Test("CSV はセミコロン区切り")
    func csvField() {
        #expect(SessionTags.csvField(["ホップ強め", "屋内"]) == "ホップ強め;屋内")
        #expect(SessionTags.csvField([]).isEmpty)
    }

    @Test("既にあるタグは足さない / 表記ゆれも外せる")
    func addRemove() {
        #expect(SessionTags.adding("屋内", to: ["屋内"]) == ["屋内"])
        #expect(SessionTags.adding("  ", to: ["屋内"]) == ["屋内"])
        #expect(SessionTags.adding("新品", to: ["屋内"]) == ["屋内", "新品"])
        #expect(SessionTags.removing("ﾌｨｰﾙﾄﾞ", from: ["フィールド", "屋内"]) == ["屋内"])
        #expect(SessionTags.removing("ﾎｯﾌﾟ", from: ["ホップ"]).isEmpty)
    }

    @Test("使ったタグはよく使う順、同数なら名前順")
    func usedOrdersByFrequency() {
        let used = SessionTags.used(in: [["屋内", "新品"], ["屋内"], ["フィールド"]])
        #expect(used.first == "屋内")
        #expect(Set(used) == ["屋内", "新品", "フィールド"])
        #expect(used.dropFirst() == ["フィールド", "新品"])
    }

    @Test("候補には既に付いているタグを出さない")
    func suggestionsExcludeCurrent() {
        let suggestions = SessionTags.suggestions(
            existing: ["屋内", "フィールド"],
            starters: ["新品", "屋内"],
            current: ["屋内"]
        )
        #expect(suggestions == ["フィールド", "新品"])
    }

    @Test("候補は上限で打ち切る")
    func suggestionsLimit() {
        let suggestions = SessionTags.suggestions(
            existing: ["a", "b", "c", "d"],
            starters: ["e"],
            current: [],
            limit: 2
        )
        #expect(suggestions == ["a", "b"])
    }
}

@Suite("SessionFilter")
struct SessionFilterTests {
    private func matches(
        _ filter: SessionFilter,
        title: String = "9月3日 次世代 M4",
        notes: String? = nil,
        tags: [String] = ["ホップ強め", "屋内"],
        gunName: String = "次世代 M4"
    ) -> Bool {
        filter.matches(title: title, notes: notes, tags: tags, gunName: gunName)
    }

    @Test("何も指定していなければ全部通る")
    func emptyFilterPassesEverything() {
        let filter = SessionFilter()
        #expect(!filter.isActive)
        #expect(matches(filter))
    }

    @Test("タグは AND（選んだ全部が付いていること）")
    func tagsAreAnded() {
        #expect(matches(SessionFilter(tags: ["屋内"])))
        #expect(matches(SessionFilter(tags: ["屋内", "ホップ強め"])))
        #expect(!matches(SessionFilter(tags: ["屋内", "新品"])))
    }

    @Test("文字検索はタイトル・メモ・タグのどれかに当たれば通る")
    func searchLooksAtTitleNotesAndTags() {
        #expect(matches(SessionFilter(searchText: "M4")))
        #expect(matches(SessionFilter(searchText: "ホップ")))
        #expect(matches(SessionFilter(searchText: "雨"), notes: "雨だったので屋内"))
        #expect(!matches(SessionFilter(searchText: "ハンドガン")))
    }

    @Test("文字検索も大文字小文字と全角半角を無視する")
    func searchIsFolded() {
        #expect(matches(SessionFilter(searchText: "m4")))
        #expect(matches(SessionFilter(searchText: "ｍ４")))
    }

    @Test("前後の空白だけの検索語は無視する")
    func blankSearchIsIgnored() {
        let filter = SessionFilter(searchText: "   ")
        #expect(!filter.isActive)
        #expect(matches(filter))
    }

    @Test("銃の名前で絞れる")
    func gunNameFilter() {
        #expect(matches(SessionFilter(gunName: "次世代 M4")))
        #expect(!matches(SessionFilter(gunName: "グロック 18C")))
    }

    @Test("条件を組み合わせると狭くなる")
    func combined() {
        var filter = SessionFilter(searchText: "M4", tags: ["屋内"], gunName: "次世代 M4")
        #expect(filter.isActive)
        #expect(matches(filter))
        filter.toggle(tag: "新品")
        #expect(!matches(filter))
        filter.toggle(tag: "新品")
        #expect(matches(filter))
        filter.clear()
        #expect(!filter.isActive)
    }
}
