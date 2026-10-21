import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var guide = Guide.shared   // 单例：Siri 捷径和界面控制同一个大脑

    var body: some View {
        RootView(guide: guide, voice: guide.voice, camera: guide.camera,
                 account: guide.account, locator: guide.locator, scout: guide.scout)
    }
}

/// 一屏到底：取景铺满（给旁边的明眼人和调试看），下面一颗巨大的开始/结束按钮。
/// 盲人用户的全部交互就是：打开App → 按下半屏任意位置 → 开口说话。
/// 右上角护航按钮：激光雷达障碍预警（本地安全层，和对话相互独立）。
private struct RootView: View {
    @ObservedObject var guide: Guide
    @ObservedObject var voice: VoiceLink
    @ObservedObject var camera: CameraManager
    @ObservedObject var account: Account
    @ObservedObject var locator: Locator
    @ObservedObject var scout: Scout

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                HStack(alignment: .top) {
                    captions
                    Spacer(minLength: 12)
                    if voice.live && guide.mode != .chat {
                        Text(guide.mode.name + "模式")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("当前是\(guide.mode.name)模式")
                    }
                    if Scout.available { scoutButton }
                }
                Spacer()
                statusLine
                bigButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .onAppear {
            locator.request()
            Task { await account.check() }
            camera.start()                                   // 提前取景，接通就有画面
            UIApplication.shared.isIdleTimerDisabled = true  // 出门导览不许锁屏
            // 盲人入口：打开 App 即自动接通（双击图标=一步到位；登录弹窗在时不抢）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !voice.live, !account.needLogin { guide.toggleCall() }
            }
            SelfTest.run(guide)   // 仅 DEBUG：真机自检，结果写 Documents/selftest.json
        }
        .onChange(of: locator.place) { _, _ in guide.placeChanged() }
        .sheet(isPresented: $account.needLogin) { LoginView(account: account) }
        .preferredColorScheme(.dark)
    }

    /// 字幕：低视力用户和旁人能看到对话内容
    private var captions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !guide.userLine.isEmpty {
                Text(guide.userLine)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
            if !guide.botLine.isEmpty {
                Text(guide.botLine)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .accessibilityHidden(true)   // 内容她都会念出来，VoiceOver 不用重复读字幕
    }

    /// 护航开关：激光雷达障碍预警。灰=关，绿=畅通，橙=注意（显示距离），红=危险
    private var scoutButton: some View {
        Button(action: guide.toggleScout) {
            VStack(spacing: 2) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .bold))
                Text(scoutLabel)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(scoutColor, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(scout.enabled ? "关闭护航" : "开启护航")
        .accessibilityHint("护航用激光雷达盯着你正前方，有障碍物靠近会震动提醒，越近震得越急")
    }

    private var scoutLabel: String {
        guard scout.enabled else { return "护航" }
        switch scout.zone {
        case .danger: return "很近!"
        case .warn: return String(format: "%.1f米", scout.distance)
        case .clear: return "畅通"
        case .off: return "护航"
        }
    }

    private var scoutColor: Color {
        guard scout.enabled else { return .black.opacity(0.45) }
        switch scout.zone {
        case .danger: return .red.opacity(0.85)
        case .warn: return .orange.opacity(0.85)
        default: return .green.opacity(0.6)
        }
    }

    private var statusLine: some View {
        Group {
            if camera.permissionDenied {
                Text("需要相机权限才能帮你看路，请到设置里打开")
            } else if guide.looking {
                Label("正在仔细看…", systemImage: "eye")
            } else if !voice.status.isEmpty {
                Text(voice.status)
            } else if voice.live {
                Label(label(for: voice.turn), systemImage: "waveform")
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private func label(for turn: VoiceLink.Turn) -> String {
        switch turn {
        case .listening: return "在听你说…"
        case .thinking: return "小路在想…"
        case .idle: return "随时开口，小路听着呢"
        }
    }

    /// 巨大按钮：占满宽度、超高、强对比；VoiceOver 有明确的名字和提示
    private var bigButton: some View {
        Button(action: guide.toggleCall) {
            VStack(spacing: 8) {
                Image(systemName: voice.live ? "stop.fill" : "mic.fill")
                    .font(.system(size: 42, weight: .bold))
                Text(voice.live ? "结束" : "开始")
                    .font(.system(size: 40, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 170)
        }
        .background(voice.live ? Color.red.opacity(0.88) : Color.green.opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityLabel(voice.live ? "结束对话" : "开始对话")
        .accessibilityHint(voice.live ? "挂断小路" : "接通小路，她会帮你看眼前的环境，直接开口问就行")
    }
}

#Preview {
    ContentView()
}
