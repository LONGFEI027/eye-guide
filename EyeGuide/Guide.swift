import SwiftUI
import UIKit
import Combine

/// 总控：接通语音、把镜头画面喂给小路、执行她调用的工具。
/// 本地即时层（不经过大模型）：护航=激光雷达障碍预警（Scout）、读字=本地 OCR 即时朗读、
/// 找东西=本地分类器报方向（Finder）。模式（聊天/行走/读字/找东西）由她调 set_mode 切换。
@MainActor
final class Guide: ObservableObject {
    static let shared = Guide()      // Siri 捷径（Intents.swift）也要控制它，单例

    @Published var userLine = ""     // 你刚说的（转写）
    @Published var botLine = ""      // 她正在说的（字幕）
    @Published var looking = false   // 正在拍照细看
    @Published var mode: GuideMode = .chat

    let voice = VoiceLink()
    let camera = CameraManager()
    let account = Account()
    let locator = Locator()
    let scout = Scout()
    let finder = Finder()

    private var bag = Set<AnyCancellable>()
    private var lastRead = ""                    // 读字模式：上一段念过的文字
    private var lastReadAt = Date.distantPast
    private var lastFindCallout = Date.distantPast
    private var findInformed = false             // 本地首次命中目标后告知她一次

    init() {
        camera.onSnapshot = { [weak self] jpeg in
            guard let self else { return }
            self.voice.sendImage(jpeg)
            switch self.mode {
            case .read: self.readTick(jpeg)
            case .find: self.findTick(jpeg)
            default: break
            }
        }
        camera.onObstacle = { [weak self] d in self?.scout.feed(d) }
        voice.onCaption = { [weak self] t in self?.botLine = t }
        voice.onUserText = { [weak self] t in self?.userLine = t }
        voice.onToolCall = { [weak self] name, args, id, spoke in self?.tool(name, args, id, spoke) }
        voice.onNeedLogin = { [weak self] in self?.account.needLogin = true }
        if scout.enabled, Scout.available {
            camera.wantsDepth = true             // 开机就带深度（configure 在 camera.start 时生效）
            scout.setEnabled(true)
        }
        // 行走模式下，雷达跨入危险档时让她知情（不开口，App已经震动+播报过了）
        scout.$zone.removeDuplicates().sink { [weak self] z in
            Task { @MainActor in
                guard let self, self.mode == .walk, self.voice.live else { return }
                if z == .danger {
                    self.voice.event("雷达：正前方1米内有障碍，App已震动提醒过对方，你不用重复", speak: false)
                }
            }
        }.store(in: &bag)
    }

    func toggleCall() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if voice.live {
            voice.stop()
            camera.wantsSnapshots = false
            camera.setTorch(false)
            userLine = ""; botLine = ""
            setMode(.chat, target: nil)          // 挂断回到默认模式
            LocalVoice.hush()
        } else {
            camera.start()
            camera.wantsSnapshots = true
            voice.start(instructions: instructions())
        }
    }

    /// 护航开关（界面按钮）：激光雷达障碍预警
    func toggleScout() {
        guard Scout.available else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let on = !scout.enabled
        scout.setEnabled(on)
        camera.setDepth(on)
        voice.refreshInstructions(instructions())
    }

    /// 位置解析出来后刷新她的上下文
    func placeChanged() { voice.refreshInstructions(instructions()) }

    private func instructions() -> String {
        Brain.instructions(place: locator.place, scout: scout.enabled,
                           extra: Brain.modeNote(mode, target: finder.target, localDetect: finder.localDetect))
    }

    // MARK: - 模式切换

    private func setMode(_ m: GuideMode, target: String?) {
        // 退出旧模式的收尾
        if mode == .read { camera.snapshotWidth = 640 }
        if mode == .find { finder.set(target: nil); findInformed = false }
        mode = m
        // 进入新模式的准备
        switch m {
        case .walk:
            if Scout.available, !scout.enabled {    // 行走自动开护航
                scout.setEnabled(true)
                camera.setDepth(true)
            }
        case .read:
            camera.snapshotWidth = 960              // 小字也要看得清
            lastRead = ""
        case .find:
            finder.set(target: target)
            lastFindCallout = .distantPast
        case .chat:
            break
        }
        voice.refreshInstructions(instructions())
    }

    // MARK: - 本地通道（读字 / 找东西，每秒一帧随 onSnapshot 进来）

    private func readTick(_ jpeg: Data) {
        guard !voice.isBusy else { return }   // 小路正在说话：本地播报让路，下一帧再来
        guard Date().timeIntervalSince(lastReadAt) > 2 else { return }
        lastReadAt = Date()
        Task { @MainActor in
            guard self.mode == .read, !self.voice.isBusy,
                  let text = await OCR.read(jpeg), text.count >= 4 else { return }
            guard OCR.similar(text, self.lastRead) < 0.6 else { return }   // 同一块牌子不重复念
            self.lastRead = text
            LocalVoice.say(String(text.prefix(60)))
        }
    }

    private func findTick(_ jpeg: Data) {
        guard !voice.isBusy else { return }   // 小路正在说话：本地播报让路，不叠音
        guard finder.localDetect, Date().timeIntervalSince(lastFindCallout) > 2.5 else { return }
        let target = finder.target ?? "目标"
        Task.detached { [weak self] in
            guard let hit = self?.finder.scan(jpeg) else { return }
            await MainActor.run {
                guard let self, self.mode == .find else { return }
                self.lastFindCallout = Date()
                LocalVoice.say("\(target)，\(hit.direction)")
                if !self.findInformed {
                    self.findInformed = true
                    self.voice.event("本地检测到\(target)在\(hit.direction)，已直接语音提示对方；他走近后你用画面帮他定位最后一步", speak: false)
                }
            }
        }
    }

    // MARK: - 工具执行

    private func tool(_ name: String, _ args: [String: Any], _ id: String, _ spoke: Bool) {
        switch name {
        case "look_closely":
            looking = true
            let q = (args["question"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "描述画面里的关键信息"
            camera.capture { [weak self] data in
                guard let self else { return }
                guard let data, let jpeg = CameraManager.downscale(data, maxWidth: 1280) else {
                    self.looking = false
                    self.voice.toolResult(callId: id, output: "拍照失败了，如实告诉对方没看成，请他举稳手机稍后再试", speak: true)
                    return
                }
                self.analyze(jpeg: jpeg, question: q, callId: id)
            }

        case "set_mode":
            let m = Tools.mode(args["mode"])
            let target = (args["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if m == .find && target == nil {
                voice.toolResult(callId: id, output: "find模式必须带target参数（要找什么），先问清对方要找什么再调用", speak: true)
                return
            }
            setMode(m, target: target)
            let note: String
            switch m {
            case .walk: note = "已进入行走模式（护航雷达已开）。简短告诉对方可以走了，路上你会提醒重要路况"
            case .read: note = "已进入读字模式，App会自动朗读镜头里的文字。简短告诉对方把手机对准要读的东西"
            case .find: note = finder.localDetect
                ? "已进入找东西模式（本地检测：\(target!)）。简短告诉对方举稳手机慢慢原地转一圈，检测到会直接报方向"
                : "已进入找东西模式（目标：\(target!)，本地不认识这个词，由你看画面找）。简短告诉对方慢慢转身让你看"
            case .chat: note = "已回到聊天模式，简短说一句即可"
            }
            voice.toolResult(callId: id, output: note, speak: true)

        case "set_zoom":
            let lens = Tools.lens(args["lens"])
            camera.setZoom(label: lens)
            voice.toolResult(callId: id, output: "已切到\(lens)倍镜头，下一帧画面就是新焦段", speak: false)

        case "set_torch":
            let on = Tools.bool(args["on"])
            camera.setTorch(on)
            voice.toolResult(callId: id, output: on ? "手电筒已打开" : "手电筒已关闭", speak: !spoke)

        default:
            voice.toolResult(callId: id, output: "没有这个工具", speak: false)
        }
    }

    /// 细看一张照片：读字类问题先走本地 OCR 快路径（亚秒级），其余交云端视觉模型
    private func analyze(jpeg: Data, question: String, callId: String) {
        Task { @MainActor in
            defer { self.looking = false }
            if OCR.isReadingQuestion(question), let text = await OCR.read(jpeg), text.count >= 6 {
                self.voice.toolResult(callId: callId,
                    output: "【本地文字识别原文，逐字准确】\n\(text)\n（按对方的问题挑相关内容念，忽略排版噪声；原文里没有对方要的信息就直说没看到）",
                    speak: true)
                return
            }
            let answer = await VisionAPI.inspect(jpeg, question: question)
                ?? "网络不太好没看成，如实告诉对方，请他稍后再问一次"
            self.voice.toolResult(callId: callId, output: answer, speak: true)
        }
    }
}
