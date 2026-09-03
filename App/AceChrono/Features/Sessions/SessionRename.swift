import SwiftData
import SwiftUI

/// セッション名を変更するアラート。一覧（スワイプ / 長押し）と詳細（鉛筆ボタン）の
/// **両方から同じ操作**を出すために、ビューモディファイアとして 1 箇所に置いてある。
///
/// 名前は 1 行のテキストで、他に決めることが無い。専用のシートや画面を出すと
/// 「戻る」操作が増えるだけなので、`.alert` の `TextField` で完結させる。
struct SessionRenameAlert: ViewModifier {
    @Binding var target: Session?

    @Environment(\.modelContext) private var modelContext
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: target) { _, newValue in
                // 既定値は「いま表示されている名前」。自動タイトルのままでも、
                // それを土台に少し直したいことが多い。
                text = newValue?.displayTitle ?? ""
            }
            .alert("名前を変更", isPresented: isPresented) {
                TextField("セッション名", text: $text)
                Button("キャンセル", role: .cancel) { target = nil }
                Button("保存") {
                    target?.setTitle(text)
                    try? modelContext.save()
                    target = nil
                }
            } message: {
                Text("空にすると、日時と銃名の自動タイトルに戻ります。")
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { target != nil },
            set: { if !$0 { target = nil } }
        )
    }
}

extension View {
    /// `session` が非 nil の間だけ名前変更アラートを出す。
    func sessionRenameAlert(target: Binding<Session?>) -> some View {
        modifier(SessionRenameAlert(target: target))
    }
}
