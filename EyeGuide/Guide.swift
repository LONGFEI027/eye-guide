import SwiftUI
import UIKit

/// 总控：接通语音、把镜头画面喂给小路、执行她调用的工具。
/// 本地即时层（不经过大模型）：护航=激光雷达障碍预警（Scout），读字=本地 OCR 快路径。
@MainActor
final class Guide: ObservableObject {
    @Published var userLine = ""     // 你刚说的（转写）
    @Published var botLine = ""      // 她正在说的（字幕）
    @Published var looking = false   // 正在拍照细看

    let voice = VoiceLink()
    let camera = CameraManager()
    let account = Account()
    let locator = Locator()
    let scout = Scout()

    init() {
        camera.onSnapshot = { [weak self] jpeg in self?.voice.sendImage(jpeg) }
        camera.onObstacle = { [weak self] d in self?.scout.feed(d) }
        voice.onCaption = { [weak self] t in self?.botLine = t }
        voice.onUserText = { [weak self] t in self?.userLine = t }
        voice.onToolCall = { [weak self] name, args, id, spoke in self?.tool(name, args, id, spoke) }
        voice.onNeedLogin = { [weak self] in self?.account.needLogin = true }
        if scout.enabled, Scout.available {
            camera.wantsDepth = true           // 开机就带深度（configure 在 camera.start 时生效）
            scout.setEnabled(true)
        }
    }

    func toggleCall() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if voice.live {
            voice.stop()
            camera.wantsSnapshots = false
            camera.setTorch(false)
            userLine = ""; botLine = ""
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
        Brain.instructions(place: locator.place, scout: scout.enabled)
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
