import AppIntents

/// Siri 一句话入口（盲人不用摸屏幕）："用小路开始对话"、"小路护航"。
/// 装机后第一次运行 App，系统才会注册这些短语。
struct StartTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "开始对话"
    static var description = IntentDescription("接通小路，开始语音对话")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let g = Guide.shared
        if !g.voice.live, !g.account.needLogin { g.toggleCall() }
        return .result()
    }
}

struct ToggleScoutIntent: AppIntent {
    static var title: LocalizedStringResource = "切换护航"
    static var description = IntentDescription("开启或关闭激光雷达障碍预警")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Guide.shared.toggleScout()
        return .result()
    }
}

struct XiaoluShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTalkIntent(),
                    phrases: ["用\(.applicationName)开始对话", "\(.applicationName)开始对话", "和\(.applicationName)说话"],
                    shortTitle: "开始对话", systemImageName: "mic.fill")
        // 注意：短语不能以"打开\(.applicationName)"开头，会跟 Siri 自带的"打开小路"（打开App）撞车，
        // 把普通的打开App劫持成护航开关（用户实测：加了"打开小路护航"后"打开小路"就失灵了）
        AppShortcut(intent: ToggleScoutIntent(),
                    phrases: ["\(.applicationName)护航", "\(.applicationName)开护航", "\(.applicationName)关护航"],
                    shortTitle: "护航", systemImageName: "dot.radiowaves.left.and.right")
    }
}
