import SwiftUI
import AppIntents

@main
struct EyeGuideApp: App {
    init() {
        // 数据线反复重装会让 Siri 的短语注册失效，启动时强制重新注册
        XiaoluShortcuts.updateAppShortcutParameters()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
