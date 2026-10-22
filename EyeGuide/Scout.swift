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
    private lazy var buf = Self.tone(freq: 1050, ms: 80)

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
            let fade = min(1, Double(min(i, n - i)) / (format.sampleRate * 0.008))
            p[i] = Float(sin(2 * .pi * freq * t) * 0.6 * fade)
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

    func tick() {
        guard Self.onBluetooth else { return }
        ensure()
        player.pan = 0
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

    private var hapticEngine: CHHapticEngine?
    private let beeper = Beeper()
    private var hapticTimer: Timer?
    private var beepTimer: Timer?
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
                retuneBeeps()
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
                    self?.pulse(1.0)
                }
            }
        } else {
            zone = .off
            hapticTimer?.invalidate(); hapticTimer = nil
            beepTimer?.invalidate(); beepTimer = nil
            holdTimer?.invalidate(); holdTimer = nil
            holding = false
            refDistance = -1; stillSince = nil
            beeper.stopEngine()
            say("护航已关闭")
        }
    }

    private func enterHold() {
        holding = true
        hapticTimer?.invalidate(); hapticTimer = nil
        beepTimer?.invalidate(); beepTimer = nil
        if !(voiceBusy?() ?? false) { say("前面一直挡着，你动的时候我再细报") }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.holding else { return }
                self.pulse(0.6)
                self.beeper.tick()
            }
        }
    }

    private func exitHold() {
        holding = false
        holdTimer?.invalidate(); holdTimer = nil
        if zone != .clear, zone != .off {
            retuneHaptics()
            retuneBeeps()
        }
    }

    // MARK: - 震动（用户实测认可的节奏，别动）

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

    private func retuneHaptics() {
        hapticTimer?.invalidate(); hapticTimer = nil
        ensureEngine()
        switch zone {
        case .danger:
            hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.enabled, self.zone == .danger, !self.holding else { return }
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

    // MARK: - 滴滴：台阶节奏，每档固定频率（可预测）

    private func retuneBeeps() {
        beepTimer?.invalidate(); beepTimer = nil
        let interval: TimeInterval
        switch zone {
        case .danger: interval = 0.125   // 8次/秒
        case .warn: interval = 0.33      // 3次/秒
        case .far: interval = 0.9        // 约1次/秒——"2米外慢慢滴"
        default: return
        }
        beeper.tick()
        beepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, !self.holding,
                      self.zone == .far || self.zone == .warn || self.zone == .danger else { return }
                self.beeper.tick()
            }
        }
    }

    // MARK: - 语音（方向唯一出口；非危险让路）

    private func announce(from old: Zone, to z: Zone, rover: Rover.Output) {
        guard Date().timeIntervalSince(lastSpoke) > 2 else { return }
        let busy = voiceBusy?() ?? false
        switch z {
        case .danger:
            say("停" + (rover.blocked ? "，" + detourText() : ""))   // 危险永远开口
        case .warn:
            if !busy { say("前方一米半有东西") }
        case .clear:
            if !busy, old == .warn || old == .danger { say("通了") }
        default:
            break   // far 档不说话，只有慢滴
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
