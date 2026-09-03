import SwiftUI

/// 本体内に溜まっているログの取り込みを知らせる帯。
///
/// **`AmmoMismatchBanner` と同じ作法**（接続ピルの直下・アラートにしない・その場で
/// 2 択）に揃えてある。取り込みは急ぐ用事ではないので、撃っている最中に画面を
/// 占領して「OK」を押させる理由が無い。進捗も結果も同じ場所で完結させ、
/// 画面遷移を起こさない。
struct DeviceLogBanner: View {
    let state: DeviceLogImportState
    /// 未取込の件数（`state == .idle` のときだけ意味がある）。
    let pendingCount: Int?
    var onImport: () -> Void
    var onDismissPending: () -> Void
    var onDismissResult: () -> Void

    var body: some View {
        switch state {
        case .idle:
            if let pendingCount {
                pending(count: pendingCount)
            }
        case .importing(let done, let total):
            importing(done: done, total: total)
        case .finished(let summary):
            finished(summary)
        }
    }

    // MARK: - 未取込

    private func pending(count: Int) -> some View {
        container(tint: .blue) {
            Label {
                Text("本体に未取込のログが \(count) 件あります")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "tray.and.arrow.down")
                    .font(.footnote)
            }
            .foregroundStyle(.blue)

            HStack(spacing: 10) {
                Button("取り込む", action: onImport)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("あとで", action: onDismissPending)
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - 取り込み中

    private func importing(done: Int, total: Int) -> some View {
        container(tint: .blue) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("本体ログを取り込み中 \(done) / \(total)")
                    .font(.footnote)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
            }
            .foregroundStyle(.blue)

            ProgressView(value: Double(done), total: Double(max(total, 1)))
        }
    }

    // MARK: - 結果

    private func finished(_ summary: DeviceLogImportSummary) -> some View {
        container(tint: summary.isSuccess ? .green : .orange) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline(summary))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = detail(summary) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: summary.isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.footnote)
            }
            .foregroundStyle(summary.isSuccess ? .green : .orange)

            HStack {
                Button("閉じる", action: onDismissResult)
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private func headline(_ summary: DeviceLogImportSummary) -> LocalizedStringKey {
        switch summary.outcome {
        case .completed:
            "本体ログ \(summary.savedShotCount) 件を取り込みました"
        case .unsupportedFormat:
            // 文言はここ 1 箇所。**「保存した」ことを先に伝える**（何も残らなかったと
            // 思わせない）。何が起きたかの詳しい話は下の行に落とす。
            "未対応の形式でした。ログを保存しました"
        case .noResponse:
            "本体から応答がありませんでした"
        }
    }

    private func detail(_ summary: DeviceLogImportSummary) -> LocalizedStringKey? {
        switch summary.outcome {
        case .completed:
            return "本体（クロノグラフ）内蔵のログから取り込みました。履歴に「本体ログ」タグで入っています。時刻は取り込んだ時刻です。"
        case .unsupportedFormat:
            guard let name = summary.debugFileName else {
                return "読めたぶんだけ履歴に保存しました。"
            }
            return "読めたぶんは履歴に、生データは \(name) に保存しました。"
        case .noResponse:
            return "本体のログ形式に対応できていない可能性があります。あとでもう一度試せます。"
        }
    }

    // MARK: - 共通の見た目

    @ViewBuilder
    private func container(
        tint: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}

#Preview("未取込") {
    DeviceLogBanner(
        state: .idle,
        pendingCount: 12,
        onImport: {},
        onDismissPending: {},
        onDismissResult: {}
    )
    .padding()
}

#Preview("取り込み中") {
    DeviceLogBanner(
        state: .importing(done: 5, total: 12),
        pendingCount: nil,
        onImport: {},
        onDismissPending: {},
        onDismissResult: {}
    )
    .padding()
}

#Preview("未対応の形式") {
    DeviceLogBanner(
        state: .finished(
            DeviceLogImportSummary(
                savedShotCount: 4,
                outcome: .unsupportedFormat,
                debugFileName: "device-log-20260903-121500.txt"
            )
        ),
        pendingCount: nil,
        onImport: {},
        onDismissPending: {},
        onDismissResult: {}
    )
    .padding()
}
