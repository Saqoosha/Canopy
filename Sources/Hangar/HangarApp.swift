import SwiftUI

@main
struct HangarApp: App {
    var body: some Scene {
        WindowGroup {
            WebViewContainer()
                .frame(minWidth: 400, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 500, height: 800)
    }
}
