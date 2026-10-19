import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var guide = Guide()

    var body: some View {
        RootView(guide: guide, voice: guide.voice, camera: guide.camera,
                 account: guide.account, locator: guide.locator, glasses: guide.glasses)
    }
}

/// 一屏到底：取景铺满（给旁边的明眼人和调试看），下面一颗巨大的开始/结束按钮。
/// 盲人用户的全部交互就是：打开App → 按下半屏任意位置 → 开口说话。
/// 右上角眼镜按钮：切到 Rokid 眼镜当眼睛（第一人称视角，解放双手）。
private struct RootView: View {
    @ObservedObject var guide: Guide
    @ObservedObject var voice: VoiceLink
    @ObservedObject var camera: CameraManager
    @ObservedObject var account: Account
    @ObservedObject var locator: Locator
    @ObservedObject var glasses: Glasses

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
                    glassesButton
                }
                if let img = glasses.lastPhoto, guide.glassesActive {
                    HStack {
                        Spacer()
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 96, height: 128).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.green.opacity(0.7), lineWidth: 2))
                            .accessibilityLabel("眼镜拍到的最新画面")
                    }
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
            if glasses.enabled { glasses.start() }           // 上次开着眼镜模式就自动续上
        }
        .onChange(of: locator.place) { _, _ in guide.placeChanged() }
        .onOpenURL { url in _ = glasses.handleOpenURL(url) } // Rokid 鉴权跳转回来
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

    /// 眼镜开关（右上角）：灰=关，黄=连接中/等授权，绿=在用眼镜看
    private var glassesButton: some View {
        Button(action: guide.toggleGlasses) {
            VStack(spacing: 2) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 22, weight: .bold))
                Text(glassesLabel)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(glassesColor, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(glasses.enabled ? "关闭眼镜模式" : "开启眼镜模式")
        .accessibilityHint("开启后小路改用你佩戴的 Rokid 眼镜看世界，双手就空出来了")
    }

    private var glassesLabel: String {
        guard glasses.enabled else { return "眼镜" }
        switch glasses.state {
        case .ready: return glasses.battery.map { "眼镜 \($0)%" } ?? "眼镜·在用"
        case .needAuth: return "去授权"
        case .connecting: return "连接中"
        case .error: return "出错了"
        case .off: return "眼镜"
        }
    }

    private var glassesColor: Color {
        guard glasses.enabled else { return .black.opacity(0.45) }
        switch glasses.state {
        case .ready: return .green.opacity(0.75)
        case .error: return .red.opacity(0.75)
        default: return .orange.opacity(0.8)
        }
    }

    private var statusLine: some View {
        Group {
            if camera.permissionDenied {
                Text("需要相机权限才能帮你看路，请到设置里打开")
            } else if case .error(let msg) = glasses.state, glasses.enabled {
                Text(msg)
            } else if guide.glassesActive && !glasses.wearing {
                Text("眼镜好像没戴着，戴上小路才看得见")
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
        case .idle: return guide.glassesActive ? "小路正用眼镜看着呢，随时开口" : "随时开口，小路听着呢"
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
