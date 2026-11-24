import SwiftUI

@main
struct FridayMainApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 700, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
