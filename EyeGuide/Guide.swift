import SwiftUI
import UIKit

/// 总控：接通语音、把镜头画面喂给小路、执行她调用的工具。
/// 对应 photo-coach 的 Director，但这里刻意简单——没有状态机，全部交互都是"她看、她说"。
@MainActor
final class Guide: ObservableObject {
    @Published var userLine = ""     // 你刚说的（转写）
    @Published var botLine = ""      // 她正在说的（字幕）
    @Published var looking = false   // 正在拍照细看

    let voice = VoiceLink()
    let camera = CameraManager()
    let account = Account()
    let locator = Locator()

    init() {
        camera.onSnapshot = { [weak self] jpeg in self?.voice.sendImage(jpeg) }
        voice.onCaption = { [weak self] t in self?.botLine = t }
        voice.onUserText = { [weak self] t in self?.userLine = t }
        voice.onToolCall = { [weak self] name, args, id, spoke in self?.tool(name, args, id, spoke) }
        voice.onNeedLogin = { [weak self] in self?.account.needLogin = true }
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
            voice.start(instructions: Brain.instructions(place: locator.place))
        }
    }

    /// 位置解析出来后刷新她的上下文
    func placeChanged() {
        voice.refreshInstructions(Brain.instructions(place: locator.place))
    }

    // MARK: - 工具执行

    private func tool(_ name: String, _ args: [String: Any], _ id: String, _ spoke: Bool) {
        switch name {
        case "look_closely":
            looking = true
            let q = (args["question"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "描述画面里的关键信息"
            camera.capture { [weak self] data in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.looking = false }
                    guard let data, let jpeg = CameraManager.downscale(data, maxWidth: 1280) else {
                        self.voice.toolResult(callId: id, output: "拍照失败了，如实告诉对方没看成，请他举稳手机稍后再试", speak: true)
                        return
                    }
                    let answer = await VisionAPI.inspect(jpeg, question: q)
                        ?? "网络不太好没看成，如实告诉对方，请他稍后再问一次"
                    self.voice.toolResult(callId: id, output: answer, speak: true)
                }
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
}
