import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var guide = Guide()

    var body: some View {
        RootView(guide: guide, voice: guide.voice, camera: guide.camera,
                 account: guide.account, locator: guide.locator)
    }
}

/// 一屏到底：取景铺满（给旁边的明眼人和调试看），下面一颗巨大的开始/结束按钮。
/// 盲人用户的全部交互就是：打开App → 按下半屏任意位置 → 开口说话。
private struct RootView: View {
    @ObservedObject var guide: Guide
    @ObservedObject var voice: VoiceLink
    @ObservedObject var camera: CameraManager
    @ObservedObject var account: Account
    @ObservedObject var locator: Locator

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                captions
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
        .accessibilityHint(voice.live ? "挂断小路" : "接通小路，她会通过摄像头帮你看眼前的环境，直接开口问就行")
    }
}

#Preview {
    ContentView()
}
