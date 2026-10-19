import SwiftUI
import UIKit
import Combine

/// 总控：接通语音、把画面喂给小路、执行她调用的工具。
/// 画面来源二选一：iPhone 后置摄像头（默认，1fps），或 Rokid 眼镜（第一人称，约 4 秒一帧——
/// 实测眼镜拍照 2.7~4 秒/张，只能走走停停地看）。look_closely 高清细看两边都支持，眼镜失败自动降级回手机。
@MainActor
final class Guide: ObservableObject {
    @Published var userLine = ""     // 你刚说的（转写）
    @Published var botLine = ""      // 她正在说的（字幕）
    @Published var looking = false   // 正在拍照细看

    let voice = VoiceLink()
    let camera = CameraManager()
    let account = Account()
    let locator = Locator()
    let glasses = Glasses()

    private var bag = Set<AnyCancellable>()
    private var frameTimer: Timer?

    init() {
        camera.onSnapshot = { [weak self] jpeg in self?.voice.sendImage(jpeg) }
        voice.onCaption = { [weak self] t in self?.botLine = t }
        voice.onUserText = { [weak self] t in self?.userLine = t }
        voice.onToolCall = { [weak self] name, args, id, spoke in self?.tool(name, args, id, spoke) }
        voice.onNeedLogin = { [weak self] in self?.account.needLogin = true }

        // 眼镜状态 / 开关 / 通话状态变化 → 重排画面来源 + 刷新她的上下文
        glasses.$state.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.sourceChanged() }
        }.store(in: &bag)
        glasses.$enabled.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.sourceChanged() }
        }.store(in: &bag)
        voice.$live.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.syncFrameSource() }
        }.store(in: &bag)
    }

    var glassesActive: Bool { glasses.enabled && glasses.state == .ready }

    func toggleCall() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if voice.live {
            voice.stop()
            camera.wantsSnapshots = false
            camera.setTorch(false)
            userLine = ""; botLine = ""
        } else {
            camera.start()
            voice.start(instructions: instructions())
        }
        syncFrameSource()
    }

    /// 眼镜开关（界面按钮）
    func toggleGlasses() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if glasses.enabled {
            glasses.enabled = false
            glasses.stop()
        } else {
            glasses.enabled = true
            glasses.start()
        }
    }

    /// 位置解析出来后刷新她的上下文
    func placeChanged() { voice.refreshInstructions(instructions()) }

    private func instructions() -> String {
        Brain.instructions(place: locator.place, glasses: glassesActive)
    }

    private func sourceChanged() {
        syncFrameSource()
        voice.refreshInstructions(instructions())
    }

    /// 画面来源仲裁：眼镜就绪→4秒一帧轮询眼镜，否则 iPhone 相机 1fps
    private func syncFrameSource() {
        let useGlasses = voice.live && glassesActive
        camera.wantsSnapshots = voice.live && !useGlasses
        if useGlasses {
            guard frameTimer == nil else { return }
            frameTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pullGlassesFrame() }
            }
            pullGlassesFrame()
        } else {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private func pullGlassesFrame() {
        guard voice.live, glassesActive else { return }
        glasses.takePhoto(width: 1280, height: 720, quality: 70) { [weak self] data in
            guard let self, let data else { return }
            self.voice.sendImage(data)    // 720p q70 约 30~60KB，满足协议 base64 ≤256KB
        }
    }

    // MARK: - 工具执行

    private func tool(_ name: String, _ args: [String: Any], _ id: String, _ spoke: Bool) {
        switch name {
        case "look_closely":
            looking = true
            let q = (args["question"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "描述画面里的关键信息"
            if glassesActive {
                // 眼镜高清单拍；失败自动降级回手机摄像头
                glasses.takePhoto(width: 1920, height: 1080, quality: 80) { [weak self] data in
                    guard let self else { return }
                    if let data {
                        self.inspect(jpeg: data, question: q, callId: id)
                    } else {
                        self.lookWithPhone(question: q, callId: id)
                    }
                }
            } else {
                lookWithPhone(question: q, callId: id)
            }

        case "set_zoom":
            if glassesActive {
                voice.toolResult(callId: id, output: "现在用的是眼镜摄像头，没有变焦，想看清楚直接用 look_closely", speak: false)
            } else {
                let lens = Tools.lens(args["lens"])
                camera.setZoom(label: lens)
                voice.toolResult(callId: id, output: "已切到\(lens)倍镜头，下一帧画面就是新焦段", speak: false)
            }

        case "set_torch":
            if glassesActive {
                voice.toolResult(callId: id, output: "眼镜上没有手电筒；画面太暗就如实告诉对方", speak: !spoke)
            } else {
                let on = Tools.bool(args["on"])
                camera.setTorch(on)
                voice.toolResult(callId: id, output: on ? "手电筒已打开" : "手电筒已关闭", speak: !spoke)
            }

        default:
            voice.toolResult(callId: id, output: "没有这个工具", speak: false)
        }
    }

    private func lookWithPhone(question: String, callId: String) {
        camera.capture { [weak self] data in
            guard let self else { return }
            guard let data, let jpeg = CameraManager.downscale(data, maxWidth: 1280) else {
                self.looking = false
                self.voice.toolResult(callId: callId, output: "拍照失败了，如实告诉对方没看成，请他举稳手机稍后再试", speak: true)
                return
            }
            self.inspect(jpeg: jpeg, question: question, callId: callId)
        }
    }

    /// 把一张 JPEG 交给视觉模型细看，结果交还给她
    private func inspect(jpeg: Data, question: String, callId: String) {
        Task { @MainActor in
            defer { self.looking = false }
            let answer = await VisionAPI.inspect(jpeg, question: question)
                ?? "网络不太好没看成，如实告诉对方，请他稍后再问一次"
            self.voice.toolResult(callId: callId, output: answer, speak: true)
        }
    }
}
