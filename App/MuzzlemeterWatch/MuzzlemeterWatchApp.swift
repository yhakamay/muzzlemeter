import SwiftUI

@main
struct MuzzlemeterWatchApp: App {
    @State private var connectivity = WatchConnectivityService()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environment(connectivity)
        }
    }
}
