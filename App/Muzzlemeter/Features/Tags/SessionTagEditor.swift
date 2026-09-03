import MuzzlemeterKit
import SwiftData
import SwiftUI

/// セッションのタグを付け外しするシート。
///
/// `@Model` のセッションを直接編集すると、キャンセルしても途中の状態が
/// ストアへ書き戻ってしまう（SwiftData の変更は即時）。`GunProfileEditor` と同じく
/// **値（`[String]`）を編集して、保存のときだけ書き戻す**。
struct SessionTagEditor: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// 候補を作るために、これまで使ったタグを全セッションから集める。
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    @State private var tags: [String]
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    init(session: Session) {
        self.session = session
        _tags = State(initialValue: session.tags)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if tags.isEmpty {
                        Text("まだタグがありません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        TagChipRow(tags: tags, onRemove: { tag in
                            withAnimation(.snappy) { tags = SessionTags.removing(tag, from: tags) }
                        })
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("付いているタグ")
                }

                Section {
                    HStack {
                        TextField("例: ホップ強め", text: $draft)
                            .focused($isFieldFocused)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("追加", action: add)
                            .disabled(!canAdd)
                    }
                } header: {
                    Text("新しいタグ")
                } footer: {
                    Text("同じタグは 2 つ付きません。大文字小文字と全角半角の違いは同じタグとして扱います。")
                }

                if !suggestions.isEmpty {
                    Section {
                        TagChipRow(tags: suggestions, action: { tag in
                            withAnimation(.snappy) { tags = SessionTags.adding(tag, to: tags) }
                        })
                        .padding(.vertical, 2)
                    } header: {
                        Text("候補")
                    } footer: {
                        Text("よく使っているタグから順に出ます。")
                    }
                }
            }
            .navigationTitle("タグ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        session.tags = tags
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }

    private var canAdd: Bool {
        let candidate = SessionTags.normalized(draft)
        return !candidate.isEmpty && !SessionTags.contains(candidate, in: tags)
    }

    private var suggestions: [String] {
        SessionTags.suggestions(
            existing: SessionTags.used(in: sessions.map(\.tags)),
            starters: SessionTagSuggestions.starters,
            current: tags
        )
    }

    private func add() {
        guard canAdd else { return }
        withAnimation(.snappy) { tags = SessionTags.adding(draft, to: tags) }
        draft = ""
        // 続けて何個か足すことが多いので、入力欄から離れない。
        isFieldFocused = true
    }
}

#Preview {
    SessionTagEditor(session: PreviewSupport.sampleSession)
        .modelContainer(PreviewSupport.container)
}
