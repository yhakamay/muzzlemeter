import MuzzlemeterKit
import SwiftData
import SwiftUI

/// セッション詳細から「他のセッションと比較」を選んだときのシート。
///
/// 履歴一覧の選択モードと同じ遷移先（`SessionComparisonRequest`）へ入るが、
/// **起点のセッションは既に決まっている**ので、選ぶのは相手（1〜2 件）だけ。
/// 一覧へ戻って選び直させると「どれと比べたかったのか」を憶えておく手間が増える。
struct SessionComparisonPicker: View {
    let base: Session

    @Environment(ChronoService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    @State private var selected: [Session] = []
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    SessionRow(session: base, speedUnit: service.speedUnit)
                } header: {
                    Text("比較のもと")
                }

                Section {
                    if candidates.isEmpty {
                        Text("比べられるセッションが他にありません。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { session in
                        SessionSelectionRow(
                            session: session,
                            speedUnit: service.speedUnit,
                            isSelected: isSelected(session),
                            isSelectable: isSelected(session) || selected.count < maximumOthers
                        ) {
                            toggle(session)
                        }
                    }
                } header: {
                    Text("比べる相手（最大 \(maximumOthers) 件）")
                }
            }
            .navigationTitle("他のセッションと比較")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SessionComparisonRequest.self) { request in
                SessionComparisonView(sessions: request.sessions)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("比較する") {
                        if let request = SessionComparisonRequest([base] + selected) {
                            path.append(request)
                        }
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    /// 起点を含めて最大 3 件なので、相手は 2 件まで。
    private var maximumOthers: Int { SessionComparisonRequest.range.upperBound - 1 }

    private var candidates: [Session] {
        sessions.filter { $0.persistentModelID != base.persistentModelID }
    }

    private func isSelected(_ session: Session) -> Bool {
        selected.contains { $0.persistentModelID == session.persistentModelID }
    }

    private func toggle(_ session: Session) {
        if let index = selected.firstIndex(where: { $0.persistentModelID == session.persistentModelID }) {
            selected.remove(at: index)
        } else if selected.count < maximumOthers {
            selected.append(session)
        }
    }
}

/// 選択モードの 1 行。チェックの丸を左に出し、行全体を押せるようにする。
///
/// `List` の `EditMode` による選択も使えるが、**上限 3 件**という制約を伝えられない
/// （選べないことをその場で示せない）ので、自前のボタン行にしてある。
struct SessionSelectionRow: View {
    let session: Session
    let speedUnit: SpeedUnit
    let isSelected: Bool
    let isSelectable: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                SessionRow(session: session, speedUnit: speedUnit)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        // 上限に達した行は押せないので、押せないことを見た目でも示す。
        .opacity(isSelectable ? 1 : 0.4)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
