import SwiftUI

@main
struct MSTAssistantApp: App {
    init() {
        Breadcrumb.mark("app init (bundle=\(Bundle.main.bundleIdentifier ?? "-"))")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { Breadcrumb.mark("ContentView appear") }
        }
    }
}
