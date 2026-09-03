import ShotLogKit
import SwiftData
import SwiftUI

@main
struct ShotLogApp: App {
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

/// 4 画面の TabView。起動時は Live。
struct RootView: View {
    @Environment(ChronoService.self) private var service
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "scope") }
            SessionsView()
                .tabItem { Label("履歴", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .task {
            service.start(modelContext: modelContext)
        }
    }
}

#Preview {
    RootView()
        .environment(ChronoService(defaults: PreviewSupport.defaults, forceReplay: true))
        .modelContainer(PreviewSupport.container)
}
