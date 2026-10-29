import SwiftUI
import UIKit
import Combine

/// 总控：接通语音、把镜头画面喂给小路、执行她调用的工具。
/// 相机双底座：护航关=AVFoundation（CameraManager，有光学变焦）；
/// 护航开=ARKit（ARCam，LiDAR深度+位姿喂 Rover 障碍引擎，Mobilio 式护航）。
/// 本地即时层（不经过大模型）：护航（Scout）、读字=本地 OCR 即时朗读、找东西=本地分类器。
@MainActor
final class Guide: ObservableObject {
    static let shared = Guide()      // Siri 捷径（Intents.swift）也要控制它，单例

    @Published var userLine = ""     // 你刚说的（转写）
    @Published var botLine = ""      // 她正在说的（字幕）
    @Published var looking = false   // 正在拍照细看
    @Published var mode: GuideMode = .chat

    let voice = VoiceLink()
    let camera = CameraManager()
    let arcam = ARCam()
    let account = Account()
    let locator = Locator()
    let scout = Scout()
    let finder = Finder()

    private var bag = Set<AnyCancellable>()
    private var lastRead = ""                    // 读字模式：上一段念过的文字
    private var lastReadAt = Date.distantPast
    private var lastFindCallout = Date.distantPast

    var scoutActive: Bool { scout.enabled && Scout.available }

    init() {
        camera.onSnapshot = { [weak self] jpeg in self?.handleSnapshot(jpeg) }
        arcam.onSnapshot = { [weak self] jpeg in self?.handleSnapshot(jpeg) }
        arcam.onObstacle = { [weak self] inst, out in self?.scout.update(instant: inst, rover: out) }
        voice.onCaption = { [weak self] t in self?.botLine = t }
        voice.onUserText = { [weak self] t in self?.userLine = t }
        voice.onToolCall = { [weak self] name, args, id, spoke in self?.tool(name, args, id, spoke) }
        voice.onNeedLogin = { [weak self] in self?.account.needLogin = true }
        scout.voiceBusy = { [weak self] in self?.voice.isBusy ?? false }   // 她说话时护航播报让路
        // 危险时让小路用自己的声音说方向（接通了才交给她；否则 Scout 本地兜底）。
        // 震动是本地即时的硬安全信号，小路的语音只是补充——她慢一点也有震动先拦着。
        scout.speakViaMoli = { [weak self] note in
            guard let self, self.voice.live else { return false }
            self.voice.event(note, speak: true)
            return true
        }
        if scout.enabled, Scout.available {
            scout.setEnabled(true)   // 上次开着就续上（底座在 startBackend 里起）
        }
    }

    /// App 启动时由界面调用：按护航状态起对应的相机底座
    func startBackend() {
        if scoutActive { arcam.start() } else { camera.start() }
    }

    private func handleSnapshot(_ jpeg: Data) {
        voice.sendImage(jpeg)
        switch mode {
        case .read: readTick(jpeg)
        case .find: findTick(jpeg)
        default: break
        }
    }

    func toggleCall() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if voice.live {
            voice.stop()
            camera.wantsSnapshots = false
            arcam.wantsSnapshots = false
            camera.setTorch(false)
            userLine = ""; botLine = ""
            setMode(.chat, target: nil)          // 挂断回到默认模式
            LocalVoice.hush()
        } else {
            startBackend()
            if scoutActive { arcam.wantsSnapshots = true } else { camera.wantsSnapshots = true }
            voice.start(instructions: instructions())
        }
    }

    /// 护航开关（界面按钮/Siri/工具）：切换相机底座 + 障碍引擎。
    /// announce=false 给工具路径用（toolResult 已让小路播报，避免两个声音）
    func toggleScout(announce: Bool = true) {
        guard Scout.available else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let on = !scout.enabled
        scout.setEnabled(on)
        if announce {
            if voice.live {
                voice.event(on ? "护航已开启，简短告诉对方一声" : "护航已关闭，简短告诉对方一声", speak: true)
            } else {
                LocalVoice.say(on ? "护航已开启" : "护航已关闭")   // 没接通时的唯一兜底
            }
        }
        if on {
            camera.wantsSnapshots = false
            camera.stop()
            arcam.start()
            arcam.wantsSnapshots = voice.live
        } else {
            arcam.wantsSnapshots = false
            arcam.stop()
            camera.start()
            camera.wantsSnapshots = voice.live
        }
        voice.refreshInstructions(instructions())
    }

    /// 位置解析出来后刷新她的上下文
    func placeChanged() { voice.refreshInstructions(instructions()) }

    private func instructions() -> String {
        Brain.instructions(place: locator.place, scout: scout.enabled,
                           extra: Brain.modeNote(mode, target: finder.target, localDetect: finder.localDetect))
    }

    // MARK: - 模式切换

    func setMode(_ m: GuideMode, target: String?) {
        // 退出旧模式的收尾
        if mode == .read { camera.snapshotWidth = 640; arcam.snapshotWidth = 640 }
        if mode == .find { finder.set(target: nil) }
        mode = m
        // 进入新模式的准备
        switch m {
        case .walk:
            if Scout.available, !scout.enabled { toggleScout(announce: false) }   // 行走自动开护航（模式播报里已带）
        case .read:
            camera.snapshotWidth = 960; arcam.snapshotWidth = 960  // 小字也要看得清
            lastRead = ""
        case .find:
            finder.set(target: target)
            lastFindCallout = .distantPast
        case .chat:
            break
        }
        voice.refreshInstructions(instructions())
    }

    // MARK: - 本地通道（读字 / 找东西，每秒一帧随 handleSnapshot 进来）

    private func readTick(_ jpeg: Data) {
        guard !voice.isBusy else { return }   // 小路正在说话：本地播报让路，下一帧再来
        guard Date().timeIntervalSince(lastReadAt) > 2 else { return }
        lastReadAt = Date()
        Task { @MainActor in
            guard self.mode == .read, !self.voice.isBusy,
                  let text = await OCR.read(jpeg), text.count >= 4 else { return }
            guard OCR.similar(text, self.lastRead) < 0.6 else { return }   // 同一段不重复念
            self.lastRead = text
            // 识别仍是本地秒级；朗读交给小路的声音（用户定稿：全程只留她一个声音）
            self.voice.event("镜头里识别到这段文字，立刻逐字念给对方听，念原文、不解释不概括：\n"
                             + String(text.prefix(300)), speak: true)
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
                // 方向播报走小路的声音（用户定稿：一个声音）
                self.voice.event("本地检测到\(target)在\(hit.direction)，立刻用最短的话告诉对方方向，比如'\(target)，\(hit.direction)'；他走近后你用画面帮他定位最后一步", speak: true)
            }
        }
    }

    // MARK: - 拍一张（look_closely 和真机自检共用；按当前底座走）

    func captureJPEG(_ completion: @escaping (Data?) -> Void) {
        if scoutActive {
            arcam.captureHiRes { data in
                completion(data.flatMap { CameraManager.downscale($0, maxWidth: 1280) ?? $0 })
            }
        } else {
            camera.capture { data in
                completion(data.flatMap { CameraManager.downscale($0, maxWidth: 1280) })
            }
        }
    }

    // MARK: - 工具执行

    private func tool(_ name: String, _ args: [String: Any], _ id: String, _ spoke: Bool) {
        switch name {
        case "look_closely":
            looking = true
            let q = (args["question"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "描述画面里的关键信息"
            captureJPEG { [weak self] jpeg in
                guard let self else { return }
                guard let jpeg else {
                    self.looking = false
                    self.voice.toolResult(callId: id, output: "拍照失败了，如实告诉对方没看成，请他稍后再试", speak: true)
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
            if scoutActive {
                voice.toolResult(callId: id, output: "护航开着时用的是广角雷达相机，没有变焦；想看清楚直接用 look_closely", speak: false)
            } else {
                let lens = Tools.lens(args["lens"])
                camera.setZoom(label: lens)
                voice.toolResult(callId: id, output: "已切到\(lens)倍镜头，下一帧画面就是新焦段", speak: false)
            }

        case "set_scout":
            guard Scout.available else {
                voice.toolResult(callId: id, output: "这台手机没有激光雷达，用不了护航", speak: true)
                return
            }
            let want = Tools.bool(args["on"])
            if want != scout.enabled { toggleScout(announce: false) }   // toolResult 会让她说，别双报
            voice.toolResult(callId: id, output: want ? "护航已打开" : "护航已关闭", speak: !spoke)

        case "set_alert_channel":
            let sv = "\(args["channel"] ?? "")".lowercased()
            let ch: Scout.AlertChannel = (sv.contains("head") || sv.contains("耳")) ? .headset : .phone
            scout.setChannel(ch)
            let note: String
            if ch == .headset {
                note = Beeper.onBluetooth
                    ? "已切到耳机震动（低频嗡声），刚震了两下让对方感受"
                    : "已设为耳机震动，但现在没检测到蓝牙耳机——接上耳机自动生效，这期间先用手机震动兜底"
            } else {
                note = "已切回手机震动"
            }
            voice.toolResult(callId: id, output: note, speak: !spoke)

        case "set_torch":
            let on = Tools.bool(args["on"])
            if scoutActive { arcam.setTorch(on) } else { camera.setTorch(on) }
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
