import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var guide = Guide.shared   // 单例：Siri 捷径和界面控制同一个大脑

    var body: some View {
        RootView(guide: guide, voice: guide.voice, camera: guide.camera, arcam: guide.arcam,
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
    @ObservedObject var arcam: ARCam
    @ObservedObject var account: Account
    @ObservedObject var locator: Locator
    @ObservedObject var scout: Scout

    var body: some View {
        ZStack {
            if guide.scoutActive && guide.mode == .walk {
                // 行走模式：机器世界——黑底 + LiDAR 三维网格线框（机器理解的世界）
                MachineWorldView(session: arcam.session)
                    .ignoresSafeArea()
            } else if guide.scoutActive {
                // 护航开着（非行走）：ARKit 原生渲染取景（共用同一个 session，流畅不卡）
                ARPreviewView(session: arcam.session)
                    .ignoresSafeArea()
            } else {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            }
            if guide.scoutActive && guide.mode == .walk {
                walkHUD.allowsHitTesting(false)   // 大号路况 HUD：低视力可读
            }
            if guide.mode == .read, !guide.readBoxes.isEmpty {
                ReadBoxesOverlay(boxes: guide.readBoxes)   // OCR 命中行高亮：机器正在念哪块字
                    .allowsHitTesting(false)
            }
            if guide.mode == .find, let dir = guide.findDirection {
                findHUD(dir).allowsHitTesting(false)       // 命中方向大箭头
            }
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    modeBar
                    Spacer(minLength: 8)
                    if Scout.available { scoutButton }
                }
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
            guide.startBackend()                             // 按护航状态起对应相机底座
            UIApplication.shared.isIdleTimerDisabled = true  // 出门导览不许锁屏
            // 盲人入口：打开 App 即自动接通（双击图标=一步到位；登录弹窗在时不抢）。
            // 快速重启时服务器上旧会话可能没断干净导致首连失败，6 秒后自动重试一次。
            // 例外：Siri"小路读书"冷启动直接进了读书模式——那是离线闭环，不自动拨通
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !voice.live, !account.needLogin, guide.mode == .chat { guide.toggleCall() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) {
                if !voice.live, !account.needLogin, guide.mode == .chat { guide.toggleCall() }
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

    /// 模式栏（顶部，和护航排一行）：四个模式独立按钮，当前模式高亮，按一下直接切（读书离线可用）
    private var modeBar: some View {
        HStack(spacing: 6) {
            modeKey(.chat, icon: "bubble.left.and.bubble.right.fill",
                    hint: "自由问答，问眼前环境、问路、聊天")
            modeKey(.walk, icon: "figure.walk",
                    hint: "小路安静护送只报重要路况，自动打开雷达护航")
            modeKey(.read, icon: "text.viewfinder",
                    hint: "对准文字自动朗读，本地识别不用联网，期间小路静音")
            modeKey(.find, icon: "magnifyingglass",
                    hint: "告诉小路要找什么，慢慢转身，找到会报方向")
        }
    }

    private func modeKey(_ m: GuideMode, icon: String, hint: String) -> some View {
        Button { guide.selectMode(m) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                Text(m.name)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(guide.mode == m ? Color.blue.opacity(0.85) : Color.black.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(guide.mode == m ? "当前是\(m.name)模式" : "切换到\(m.name)模式")
        .accessibilityHint(hint)
    }

    /// 行走模式的大号路况 HUD：低视力用户隔着半米也能看清。危险=整屏红雾+停+绕行方向；
    /// 注意=大字距离；畅通=绿色小提示。纯盲用户不靠它（震动+语音是主通道）
    private var walkHUD: some View {
        ZStack {
            if scout.zone == .danger {
                Color.red.opacity(0.22).ignoresSafeArea()   // 整屏红雾：危险一眼可辨
            }
            VStack(spacing: 2) {
                switch scout.zone {
                case .danger:
                    Text("停")
                        .font(.system(size: 110, weight: .black))
                        .foregroundStyle(.red)
                    Text(scout.detourDeg > 15 ? "往右绕 →" : (scout.detourDeg < -15 ? "← 往左绕" : "前方受阻"))
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(.white)
                case .warn, .far:
                    Text(String(format: "%.1f", scout.distance))
                        .font(.system(size: 96, weight: .black))
                        .foregroundStyle(scout.zone == .warn ? .orange : .teal)
                    + Text(" 米")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                case .clear:
                    Text("畅通")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(.green.opacity(0.85))
                case .off:
                    EmptyView()
                }
            }
            .shadow(color: .black.opacity(0.8), radius: 6)
        }
        .animation(.easeOut(duration: 0.15), value: scout.zone)
        .accessibilityHidden(true)   // 震动和语音已覆盖，VoiceOver 不重复
    }

    /// 找东西命中 HUD：大箭头 + 目标名·方向（命中后亮 2 秒多，低视力一眼可辨）
    private func findHUD(_ dir: String) -> some View {
        VStack(spacing: 4) {
            if let arrow = Self.findArrow(dir) {
                Text(arrow)
                    .font(.system(size: 120, weight: .black))
                    .foregroundStyle(.green)
            }
            Text("\(guide.finder.target ?? "目标") · \(dir)")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .shadow(color: .black.opacity(0.8), radius: 6)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: dir)
        .accessibilityHidden(true)   // 方向已经语音报过，VoiceOver 不重复
    }

    private static func findArrow(_ dir: String) -> String? {
        if dir.contains("十点") { return "↖" }
        if dir.contains("两点") { return "↗" }
        if dir.hasPrefix("正前方") && dir.count <= 4 { return "↑" }
        return nil   // "正前方一带，慢慢转一下…"这类长提示只显示文字
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
        case .far: return String(format: "%.1f米", scout.distance)
        case .clear: return "畅通"
        case .off: return "护航"
        }
    }

    private var scoutColor: Color {
        guard scout.enabled else { return .black.opacity(0.45) }
        switch scout.zone {
        case .danger: return .red.opacity(0.85)
        case .warn: return .orange.opacity(0.85)
        case .far: return .teal.opacity(0.75)
        default: return .green.opacity(0.6)
        }
    }

    private var statusLine: some View {
        Group {
            if camera.permissionDenied {
                Text("需要相机权限才能帮你看路，请到设置里打开")
            } else if scout.zone == .danger || scout.zone == .warn {
                Text(scout.detourDeg > 15 ? "↱ 往右绕" : (scout.detourDeg < -15 ? "↰ 往左绕" : "前方受阻"))
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

/// 读书模式的 OCR 高亮框：把 Vision 归一化框（原点左下，相对 3:4 竖图）
/// 映射到 aspect-fill 铺满屏幕的取景上。帧照片 1 秒一张，框有半拍延迟，读字时手机基本端稳，够用
private struct ReadBoxesOverlay: View {
    let boxes: [CGRect]

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            // 相机帧转正后是 3:4 竖图，预览按 aspect-fill 撑满屏幕
            let scale = max(W / 3, H / 4)
            let dispW = 3 * scale, dispH = 4 * scale
            let offX = (W - dispW) / 2, offY = (H - dispH) / 2
            ForEach(Array(boxes.enumerated()), id: \.offset) { _, b in
                let w = b.width * dispW, h = b.height * dispH
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow.opacity(0.9), lineWidth: 2)
                    .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: w, height: h)
                    .position(x: offX + b.minX * dispW + w / 2,
                              y: offY + (1 - b.maxY) * dispH + h / 2)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.25), value: boxes)
    }
}

#Preview {
    ContentView()
}
