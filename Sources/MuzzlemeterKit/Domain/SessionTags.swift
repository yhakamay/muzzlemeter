import Foundation

/// Pure logic for handling session tags (e.g. "heavy hop", "outdoor field").
///
/// `Session` stores tags as **a single newline-separated column** (not enough of them to
/// warrant a separate table). Unless the conversion between string and array, the
/// dedup rule, and how search matches are all kept in one place, "the same tag" ends up
/// judged differently between the save path and the filter path.
public enum SessionTags {
    /// The separator used when saving. A tag itself can't contain a newline.
    public static let separator = "\n"
    /// The separator used in CSV output. Comma would collide with the CSV delimiter, so
    /// semicolon is used instead.
    public static let csvSeparator = ";"

    /// Normalizes a string into a form usable as a single tag: trims surrounding
    /// whitespace and collapses newlines to spaces.
    public static func normalized(_ tag: String) -> String {
        tag.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The key used to decide whether two tags are "the same."
    ///
    /// Case and full-width/half-width forms are ignored — e.g. "HOP" and "hop", or a
    /// half-width and full-width katakana spelling of the same word, are the same tag.
    /// **Dakuten (voicing marks) are not ignored**: in Japanese, e.g. "ハス" (hasu,
    /// "lotus") and "バス" (basu, "bus") are different words, so folding away the
    /// voicing mark would merge tags that mean different things.
    ///
    /// A half-width dakuten/handakuten mark on its own is a **non-combining** character
    /// (U+309B / U+309C) that doesn't attach to the preceding character just by
    /// width-normalizing it, so it's remapped to the combining form (U+3099 / U+309A)
    /// before composing. Without this step, a half-width "do" spelled as
    /// base-kana-plus-mark would stay as "the base kana + a separate mark" and never
    /// match the precomposed voiced kana.
    public static func key(_ tag: String) -> String {
        let folded = normalized(tag).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return folded
            .replacingOccurrences(of: "\u{309B}", with: "\u{3099}")
            .replacingOccurrences(of: "\u{309C}", with: "\u{309A}")
            .precomposedStringWithCanonicalMapping
    }

    /// Turns a saved string into an array of tags. Drops empty elements and duplicates
    /// (**keeping whichever occurrence came first**).
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

    /// Folds an array back into the single-column form used for saving. Runs through
    /// `parse` first, so round-tripping never grows the list.
    public static func joined(_ tags: [String]) -> String {
        parse(tags.joined(separator: separator)).joined(separator: separator)
    }

    /// The form written into a single CSV cell (e.g. `heavy hop;outdoor`).
    public static func csvField(_ tags: [String]) -> String {
        parse(tags.joined(separator: separator)).joined(separator: csvSeparator)
    }

    /// Adds a tag. Does nothing if it's already present (including spelling variants).
    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        let candidate = normalized(tag)
        guard !candidate.isEmpty else { return tags }
        guard !tags.contains(where: { key($0) == key(candidate) }) else { return tags }
        return tags + [candidate]
    }

    /// Removes a tag. Spelling variants count as a match too.
    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { key($0) != key(tag) }
    }

    public static func contains(_ tag: String, in tags: [String]) -> Bool {
        tags.contains { key($0) == key(tag) }
    }

    /// Orders every tag ever used by **frequency first, then name**.
    ///
    /// Frequency rather than recency, because when shown as suggestions, putting "the
    /// tags you always use" near the top saves keystrokes.
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

    /// Suggested tags to offer as input. **Already-applied tags are excluded** (a
    /// suggestion that does nothing when tapped just gets in the way).
    ///
    /// - Parameters:
    ///   - existing: tags used before (the result of `used(in:)`)
    ///   - starters: default suggestions to fall back on when there's no history
    ///   - current: the tags already applied
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

/// History filter conditions: text search, tags (AND), and gun name.
///
/// A value meant to be applied to **an already-fetched array**, not turned into a
/// SwiftData predicate. The row count is at most a few hundred and tags are a single
/// string column, so this reads more clearly than a `#Predicate` — and, more importantly,
/// **it can be tested**.
public struct SessionFilter: Sendable, Equatable {
    /// Text search across title, notes, and tags.
    public var searchText: String
    /// The selected tags. Keeps **only sessions that have all of them** (AND).
    public var tags: [String]
    /// Gun name (the snapshot recorded on the session). `nil` means all.
    public var gunName: String?

    public init(searchText: String = "", tags: [String] = [], gunName: String? = nil) {
        self.searchText = searchText
        self.tags = tags
        self.gunName = gunName
    }

    /// Whether any filter is active. Used to decide whether the UI shows a "clear" button.
    public var isActive: Bool {
        !trimmedSearchText.isEmpty || !tags.isEmpty || gunName != nil
    }

    public var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this matches the given criteria.
    ///
    /// Tags are **AND**ed (matches the intuition that adding conditions should narrow
    /// the result). Text search matches **if it's found in any** of title, notes, or
    /// tags (OR).
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

    /// Toggles a tag in the selection (removes it if present, adds it otherwise).
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
