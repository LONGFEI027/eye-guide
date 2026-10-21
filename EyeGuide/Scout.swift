import Foundation
import UIKit
import AVFoundation
import CoreHaptics

/// 滴滴声通道（Mobilio 式）：节奏=距离（1.5m 约2次/秒 → 0.2m 封顶约11.7次/秒），
/// 声像=绕行方向（滴滴从哪边来就往哪边走）。走当前音频路由（蓝牙耳机）。
@MainActor
final class Beeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false
    private lazy var buf = Self.tone(freq: 1175, ms: 70)

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private static func tone(freq: Double, ms: Double) -> AVAudioPCMBuffer? {
        let n = Int(format.sampleRate * ms / 1000)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let p = buf.floatChannelData![0]
        for i in 0..<n {
            let t = Double(i) / format.sampleRate
            let fade = min(1, Double(min(i, n - i)) / (format.sampleRate * 0.008))   // 8ms 淡入淡出防爆音
            p[i] = Float(sin(2 * .pi * freq * t) * 0.6 * fade)
        }
        return buf
    }

    private func ensure() {
        if !started {
            let s = AVAudioSession.sharedInstance()
            if s.category != .playAndRecord {      // 通话没开时自备会话；开了就用通话的
                try? s.setCategory(.playback, options: [.mixWithOthers])
                try? s.setActive(true)
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.format)
            started = true
        }
        if !engine.isRunning { try? engine.start(); player.play() }
    }

    /// pan ∈ [-1,1]：滴滴声来自要去的方向
    func tick(pan: Float) {
        ensure()
        player.pan = max(-1, min(1, pan))
        if let b = buf { player.scheduleBuffer(b, completionHandler: nil) }
    }

    func stopEngine() { if engine.isRunning { engine.pause() } }
}

/// 护航：Mobilio 式障碍预警（本地安全层，完全不经过大模型）。
/// 输入来自 Rover（体素栅格+走廊判定+绕行方向，路过的行人靠格子衰减自动过滤）。
/// 提示三通道：震动（危险档密震）+ 滴滴声像（方向=往哪绕）+ 短语音（跨档时）。
/// 定位是"白手杖的补充"——管胸口高度的障碍；台阶、坑、地面落差靠盲杖。
@MainActor
final class Scout: ObservableObject {
    enum Zone: Int { case off = 0, clear, warn, danger }
    @Published var zone: Zone = .off
    @Published var distance: Float = 0           // 走廊内最近障碍（米）
    @Published var detourDeg: Float = 0          // 绕行方向（右正左负）
    @Published var enabled = UserDefaults.standard.bool(forKey: "scout.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "scout.enabled") }
    }
    static let available = ARCam.supported

    private var hapticEngine: CHHapticEngine?
    private let beeper = Beeper()
    private var hapticTimer: Timer?
    private var beepTimer: Timer?
    private var lastSpoke = Date.distantPast

    // MARK: - 主入口：Rover 输出（约6Hz）

    func update(_ o: Rover.Output) {
        guard enabled else { return }
        distance = o.blocked ? o.closest : 0
        detourDeg = o.detourDeg
        let newZone: Zone = o.blocked ? (o.closest < 1.0 ? .danger : .warn) : .clear
        if newZone != zone {
            zone = newZone
            announce(newZone)
            retuneHaptics()
            retuneBeeps()
        } else if o.blocked {
            retuneBeeps()   // 距离在变，滴滴节奏跟着变
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            // iOS 默认在录音期间屏蔽触感震动，显式放行
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            ensureEngine()
            zone = .clear
            say("护航已开启")
            for i in 0..<3 {   // 连震三下：当场验证震动通路
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak self] in
                    self?.pulse(1.0)
                }
            }
        } else {
            zone = .off
            hapticTimer?.invalidate(); hapticTimer = nil
            beepTimer?.invalidate(); beepTimer = nil
            beeper.stopEngine()
            say("护航已关闭")
        }
    }

    // MARK: - 震动（用户实测可用的 CoreHaptics 版，别动）

    private func ensureEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, hapticEngine == nil else { return }
        let e = try? CHHapticEngine()
        e?.playsHapticsOnly = true
        e?.resetHandler = { [weak e] in try? e?.start() }
        try? e?.start()
        hapticEngine = e
    }

    private func pulse(_ intensity: Float) {
        if let e = hapticEngine {
            let ev = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
            ], relativeTime: 0)
            if let pat = try? CHHapticPattern(events: [ev], parameters: []),
               let p = try? e.makePlayer(with: pat) {
                try? e.start()
                if (try? p.start(atTime: CHHapticTimeImmediate)) != nil { return }
            }
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)   // 兜底：老式整机震动
    }

    /// 危险档持续密震；注意档进档双震（胸前支架场景持续震太烦，实测反馈）
    private func retuneHaptics() {
        hapticTimer?.invalidate(); hapticTimer = nil
        ensureEngine()
        switch zone {
        case .danger:
            hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.enabled, self.zone == .danger else { return }
                    self.pulse(1.0)
                }
            }
        case .warn:
            pulse(0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.pulse(0.8) }
        default:
            break
        }
    }

    // MARK: - 滴滴声（Mobilio：节奏=距离，声像=绕行方向）

    private func retuneBeeps() {
        beepTimer?.invalidate(); beepTimer = nil
        guard zone == .warn || zone == .danger else { return }
        // 1.5m→2Hz，0.2m→11.7Hz（Mobilio 参数）
        let d = max(0.2, min(Rover.distanceToObstacle, distance))
        let t = Double((d - 0.2) / (Rover.distanceToObstacle - 0.2))
        let rate = 11.72 - t * 9.72
        let pan = sin(detourDeg * .pi / 180)
        beeper.tick(pan: pan)
        beepTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / rate, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.zone == .warn || self.zone == .danger else { return }
                self.beeper.tick(pan: sin(self.detourDeg * .pi / 180))
            }
        }
    }

    // MARK: - 短语音（跨档时一句，2 秒限频）

    private func announce(_ z: Zone) {
        guard Date().timeIntervalSince(lastSpoke) > 2 else { return }
        switch z {
        case .danger:
            say("停，" + detourText())
        case .warn:
            say(String(format: "前方%.0f米有挡，", max(1, distance.rounded())) + detourText())
        case .clear:
            say("通了")
        case .off:
            break
        }
    }

    private func detourText() -> String {
        let deg = detourDeg
        if abs(deg) < 15 { return "先停一下" }
        let side = deg > 0 ? "右" : "左"
        if abs(deg) < 50 { return "往\(side)一点" }
        return "往\(side)边绕"
    }

    private func say(_ text: String) {
        lastSpoke = Date()
        LocalVoice.say(text)
    }
}
