import MuzzlemeterKit
import SwiftData
import SwiftUI

@main
struct MuzzlemeterApp: App {
    /// SwiftData のコンテナ。3 モデルとも同じストアに入れる。
    let modelContainer: ModelContainer = {
        let schema = Schema([Session.self, ShotRecord.self, GunProfile.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            // 開発中にスキーマを変えた場合など、ここで落ちる。原因が分かるように潰さない。
            fatalError("ModelContainer を作成できません: \(error)")
        }
    }()

    @State private var service = ChronoService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(service)
        }
        .modelContainer(modelContainer)
    }
}

/// タブの識別子。`--demo-tab` で起動時のタブを選べるようにするために名前を付けてある。
enum RootTab: String, Hashable {
    case live
    case sessions
    case settings
}

/// 3 画面の TabView。起動時は Live。
struct RootView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab: RootTab =
        ScreenshotSupport.initialTab.flatMap(RootTab.init(rawValue:)) ?? .live

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveView()
                .tabItem { Label("Live", systemImage: "scope") }
                .tag(RootTab.live)
            SessionsView()
                .tabItem { Label("履歴", systemImage: "list.bullet.rectangle") }
                .tag(RootTab.sessions)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .task {
            // 見本データは**サービスを起動する前**に入れる。あとから入れると、
            // 既定プロファイルの自動作成（`restoreSelectedProfileIfNeeded`）と
            // 見本のプロファイルが二重に並ぶ。
            ScreenshotSupport.seedDemoSessionsIfNeeded(modelContext: modelContext)
            service.start(modelContext: modelContext)
        }
    }
}

#Preview {
    RootView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
