import SwiftUI

@main
struct ClimbColorApp: App {
    @StateObject private var appModel = ClimbColorViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}
