import MuzzlemeterKit
import SwiftUI

/// ホーム画面ウィジェット（`SessionSummaryWidget`）の中身の View。
///
/// **このファイルはアプリ本体とウィジェット拡張の両方のターゲットに含める**
/// （`project.yml` の `App/Shared`）。シミュレータでは自動操作でウィジェット
/// ギャラリーを開けないため、アプリ側の目視確認用画面（`LiveActivityPreviewHost`）
/// から同じ View を直接インスタンス化して見た目を確かめる。
struct SessionSummaryWidgetView: View {
    let family: WidgetFamilyKind
    let snapshot: HomeWidgetSnapshot?

    var body: some View {
        if let snapshot {
            switch family {
            case .medium: MediumSummaryView(snapshot: snapshot)
            case .small: SmallSummaryView(snapshot: snapshot)
            }
        } else {
            EmptySummaryView()
        }
    }
}

/// `WidgetKit.WidgetFamily` はウィジェット拡張側にしか無いので、アプリ側からも
/// 使えるよう最小限の区別だけをここで持つ（`.systemSmall` / `.systemMedium` の対応）。
enum WidgetFamilyKind {
    case small
    case medium
}

/// まだ 1 回もセッションを終えていないときの表示。
struct EmptySummaryView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("まだ記録がありません")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SmallSummaryView: View {
    let snapshot: HomeWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.gunName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let mean = snapshot.formattedMeanSpeed {
                Text(mean)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.system(.title, design: .rounded, weight: .bold))
            }
            Text("\(snapshot.shotCount) 発 · 平均")
                .font(.caption2)
                .foregroundStyle(.secondary)
            OverLimitBadge(count: snapshot.overLimitCount)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MediumSummaryView: View {
    let snapshot: HomeWidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.gunName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(snapshot.endedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                OverLimitBadge(count: snapshot.overLimitCount)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if let mean = snapshot.formattedMeanSpeed {
                    Text(mean)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.system(.title, design: .rounded, weight: .bold))
                }
                Text("平均弾速 · \(snapshot.shotCount) 発")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let joules = snapshot.formattedMeanJoules {
                    Text("平均 \(joules)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 「超過 2 発」のような小さなバッジ。0 発なら何も出さない（越えていないのが平常）。
struct OverLimitBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("超過 \(count) 発", systemImage: "exclamationmark.octagon.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
}

extension HomeWidgetSnapshot {
    /// ギャラリーのプレビュー用の見本値（製品の文言ではないので String Catalog に載せない）。
    static let previewSample = HomeWidgetSnapshot(
        title: "スプリング交換後",
        gunName: "次世代 M4",
        shotCount: 6,
        meanSpeedMetersPerSecond: 88.9,
        meanJoules: 0.94,
        overLimitCount: 0,
        endedAt: Date(),
        speedUnit: .metersPerSecond
    )
}
