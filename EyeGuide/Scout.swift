import Foundation
import UIKit
import AVFoundation
import CoreHaptics

/// 滴滴声通道：单一音调、台阶式节奏（像倒车雷达），只在蓝牙耳机接着时启用。
/// 不做任何方向编码——骨传导的颅骨串声让短音的声像/音调定位都不可靠（用户实测确认），
/// 方向信息一律交给语音（"往左绕/往右绕"）。
@MainActor
final class Beeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false
    private lazy var buf = Self.tone(freq: 880, ms: 80)   // 880Hz 比 1050 柔，骨传导不扎

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    /// 当前声音是否走蓝牙耳机（滴滴只在耳机通道响；外放靠震动+语音，免得吵）
    static var onBluetooth: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    private static func tone(freq: Double, ms: Double) -> AVAudioPCMBuffer? {
        let n = Int(format.sampleRate * ms / 1000)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let p = buf.floatChannelData![0]
        for i in 0..<n {
            let t = Double(i) / format.sampleRate
            let fade = min(1, Double(min(i, n - i)) / (format.sampleRate * 0.015))   // 15ms 缓起缓收
            p[i] = Float(sin(2 * .pi * freq * t) * 0.5 * fade)
        }
        return buf
    }

    private func ensure() {
        if !started {
            let s = AVAudioSession.sharedInstance()
            if s.category != .playAndRecord {
                try? s.setCategory(.playback, options: [.mixWithOthers])
                try? s.setActive(true)
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.format)
            started = true
        }
        if !engine.isRunning { try? engine.start(); player.play() }
    }

    /// volume 0~1：按档位分级（远档最轻），用户反馈"穿透太强滴得头疼"后整体大降
    private lazy var buzzBuf = Self.tone(freq: 150, ms: 140)   // 低频嗡声：骨传导耳机上体感即震动

    /// 耳机"震动"：低频嗡声走蓝牙。骨传导的发声单元本身是震动器，150Hz 贴颧骨=真实震感
    func buzz(volume: Float) {
        ensure()   // 先激活会话再查路由（否则未激活时误报扬声器）
        guard Self.onBluetooth else { return }
        player.pan = 0
        player.volume = max(0, min(1, volume))
        if let b = buzzBuf { player.scheduleBuffer(b, completionHandler: nil) }
    }

    func tick(volume: Float = 0.3) {
        ensure()   // 必须先激活会话再查路由：会话未激活时 currentRoute 会误报成扬声器→永远静音（实测踩坑）
        guard Self.onBluetooth else { return }
        player.pan = 0
        player.volume = volume
        if let b = buf { player.scheduleBuffer(b, completionHandler: nil) }
    }

    func stopEngine() { if engine.isRunning { engine.pause() } }
}

/// 护航（2026-10-22 按用户实测定稿的简化方案）：
/// - 测距 = 正前方即时距离（简单可预测，侧面不乱入）
/// - 滴滴 = 距离的台阶节奏：>2.5m 安静，1.5~2.5m 慢滴，1~1.5m 中速，<1m 急促
/// - 震动 = 用户认可的节奏：危险档密震、注意档进档双震
/// - 方向 = 只走语音（危险时"停，往X绕"，来自 Mobilio 世界模型），滴滴不编码方向
/// - 她说话时非危险播报让路；站着不动 4 秒降为轻提醒
@MainActor
final class Scout: ObservableObject {
    enum Zone: Int { case off = 0, clear, far, warn, danger }
    @Published var zone: Zone = .off
    @Published var distance: Float = 0
    @Published var detourDeg: Float = 0
    @Published var holding = false
    @Published var enabled = UserDefaults.standard.bool(forKey: "scout.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "scout.enabled") }
    }
    static let available = ARCam.supported

    /// 小路（大模型语音）是否正在说话——非危险播报让路
    var voiceBusy: (() -> Bool)?
    /// 危险时交给小路用她自己的声音说方向；返回 true=小路会说（本地就不说），false/nil=本地兜底
    var speakViaMoli: ((String) -> Bool)?

    /// 障碍提醒走哪个震动通道：手机马达 / 耳机低频嗡声（骨传导上即震感），语音可切换
    enum AlertChannel: String { case phone, headset }
    @Published var alertChannel: AlertChannel =
        AlertChannel(rawValue: UserDefaults.standard.string(forKey: "scout.alert") ?? "phone") ?? .phone

    func setChannel(_ c: AlertChannel) {
        alertChannel = c
        UserDefaults.standard.set(c.rawValue, forKey: "scout.alert")
        for i in 0..<2 {   // 切完立刻来两下，当场感受新通道
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 * Double(i)) { [weak self] in
                self?.alert(1.0)
            }
        }
    }

    private let buzzer = Beeper()

    /// 统一提醒出口：按通道分发；选了耳机但没连蓝牙时自动退回手机震动
    private func alert(_ intensity: Float) {
        if alertChannel == .headset, Beeper.onBluetooth {
            buzzer.buzz(volume: 0.35 + 0.65 * intensity)
        } else {
            pulse(intensity)
        }
    }

    private var hapticEngine: CHHapticEngine?
    private var hapticTimer: Timer?
    private var lastSpoke = Date.distantPast
    private var refDistance: Float = -1
    private var stillSince: Date?
    private var holdTimer: Timer?

    // MARK: - 主入口（约6Hz）

    func update(instant: Float, rover: Rover.Output) {
        guard enabled else { return }
        distance = instant
        detourDeg = rover.blocked ? rover.detourDeg : 0

        // 带滞回的台阶分档（全部基于即时距离）
        let z = zoned(instant)

        // 静止抑制：近距（warn/danger）且 4 秒距离不变 → 轻提醒；动了恢复
        if z == .warn || z == .danger {
            if refDistance < 0 || abs(instant - refDistance) > 0.15 {
                refDistance = instant
                stillSince = Date()
                if holding { exitHold() }
            } else if !holding, let s = stillSince, Date().timeIntervalSince(s) > 4 {
                enterHold()
            }
        } else {
            refDistance = -1
            stillSince = nil
            if holding { exitHold() }
        }

        if z != zone {
            let old = zone
            zone = z
            if !holding {
                announce(from: old, to: z, rover: rover)
                retuneHaptics()
            }
        }
    }

    /// 滞回分档：进档和出档的门限错开 0.15m，避免边界抖动
    private func zoned(_ d: Float) -> Zone {
        switch zone {
        case .danger: return d > 1.15 ? base(d) : .danger
        case .warn:   return d < 1.0 ? .danger : (d > 1.65 ? base(d) : .warn)
        case .far:    return d < 1.5 ? base(d) : (d > 2.7 ? .clear : .far)
        default:      return base(d)
        }
    }

    private func base(_ d: Float) -> Zone {
        d < 1.0 ? .danger : (d < 1.5 ? .warn : (d < 2.5 ? .far : .clear))
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            ensureEngine()
            zone = .clear
            say("护航已开启")
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak self] in
                    self?.alert(1.0)
                }
            }
        } else {
            zone = .off
            hapticTimer?.invalidate(); hapticTimer = nil
            holdTimer?.invalidate(); holdTimer = nil
            holding = false
            refDistance = -1; stillSince = nil
            say("护航已关闭")
        }
    }

    private func enterHold() {
        holding = true
        hapticTimer?.invalidate(); hapticTimer = nil
        // 静止不打扰：只留每3秒一次轻震提示"障碍还在"，不出声
        holdTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.holding else { return }
                self.alert(0.5)
            }
        }
    }

    private func exitHold() {
        holding = false
        holdTimer?.invalidate(); holdTimer = nil
        if zone != .clear, zone != .off {
            retuneHaptics()
        }
    }

    // MARK: - 震动（距离的台阶节奏；滴滴声已删，节奏全部走震动）

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
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    /// 距离的台阶节奏，全部走震动（滴滴声已删）：越近越密。用户已验证这个节奏手感。
    private func retuneHaptics() {
        hapticTimer?.invalidate(); hapticTimer = nil
        ensureEngine()
        let interval: TimeInterval
        let intensity: Float
        switch zone {
        case .danger: interval = 0.15; intensity = 1.0    // 1米内：密震
        case .warn:   interval = 0.33; intensity = 0.8    // 1~1.5米：中速
        case .far:    interval = 0.9;  intensity = 0.5    // 1.5~2.5米：慢震（替代"2米慢滴"）
        default: return                                   // clear：不震
        }
        alert(intensity)
        hapticTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, !self.holding,
                      self.zone == .far || self.zone == .warn || self.zone == .danger else { return }
                self.alert(intensity)
            }
        }
    }

    // MARK: - 语音（只在危险时开口；优先让小路用自己的声音说，本地只兜底）

    private func announce(from old: Zone, to z: Zone, rover: Rover.Output) {
        guard Date().timeIntervalSince(lastSpoke) > 2 else { return }
        switch z {
        case .danger:
            // 危险=唯一开口的时机：方向交给小路，她没接通时本地兜底一句
            let dir = rover.blocked ? detourText() : "先停一下"
            let note = "前方很近有障碍，提醒对方停一下，" + dir
            if speakViaMoli?(note) != true { say("停，" + dir) }
            lastSpoke = Date()
        default:
            break   // far/warn 只有震动；通畅不播报（整个对话交给小路）
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
