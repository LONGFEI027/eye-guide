import Foundation
import UIKit
import AVFoundation
import CoreHaptics
import AudioToolbox

/// 护航：激光雷达障碍预警（本地安全层，完全不经过大模型）。
/// 设计仿倒车雷达：距离越近震动越密；跨档时用系统 TTS 说一句很短的话。
/// 定位依然是"白手杖的补充"——提醒的是胸口高度的障碍（树枝、柜角、人），
/// 地面细节（台阶沿、坑）仍然靠盲杖，这一点写进了提示语。
@MainActor
final class Scout: ObservableObject {
    enum Zone: Int { case off = 0, clear, warn, danger }
    @Published var zone: Zone = .off
    @Published var distance: Float = 0          // 最近障碍（米）
    @Published var enabled = UserDefaults.standard.bool(forKey: "scout.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "scout.enabled") }
    }
    static let available = CameraManager.lidarAvailable

    private var hapticEngine: CHHapticEngine?
    private var hapticTimer: Timer?
    private var lastSpoke = Date.distantPast
    private var lastZoneChange = Date.distantPast

    /// CoreHaptics 引擎（比 UIFeedbackGenerator 可靠：不受"系统触感"开关限制）
    private func ensureEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, hapticEngine == nil else { return }
        let e = try? CHHapticEngine()
        e?.playsHapticsOnly = true
        e?.resetHandler = { [weak e] in try? e?.start() }
        try? e?.start()
        hapticEngine = e
    }

    /// 单次脉冲：CoreHaptics 优先，不行就退到老式整机震动（最强兜底，所有机器都会动）
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

    /// 深度流入口（CameraManager.onObstacle，约 10Hz，主线程）
    func feed(_ d: Float) {
        guard enabled else { return }
        distance = d
        // 带滞回的分档：进档和出档的门限错开，避免在边界上来回跳
        let newZone: Zone
        switch zone {
        case .danger: newZone = d > 1.3 ? (d > 2.6 ? .clear : .warn) : .danger
        case .warn:   newZone = d < 1.0 ? .danger : (d > 2.6 ? .clear : .warn)
        default:      newZone = d < 1.0 ? .danger : (d < 2.2 ? .warn : .clear)
        }
        if newZone != zone {
            // 档位要稳住 0.4 秒才算数（走路时手机晃动会扫过近处物体）
            if Date().timeIntervalSince(lastZoneChange) < 0.4 && newZone.rawValue > zone.rawValue { return }
            lastZoneChange = Date()
            zone = newZone
            announce(newZone)
            retune()
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            // iOS 默认在麦克风录音期间屏蔽触感震动（通话中测=完全不震），显式放行
            try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            ensureEngine()
            zone = .clear
            say("护航已开启")
            // 开启即连震三下：当场验证这台手机的震动通路
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak self] in
                    self?.pulse(1.0)
                }
            }
        } else {
            zone = .off
            hapticTimer?.invalidate(); hapticTimer = nil
            say("护航已关闭")
        }
    }

    /// 震动策略（2026-10-21 按用户实测改）：手机挂胸前，持续震太烦——
    /// 注意档只在进档时震两下提示；只有危险档（1米内）才持续密震（安全优先）。
    private func retune() {
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

    /// 跨档播报：只说最短的话，2 秒内不重复
    private func announce(_ z: Zone) {
        guard Date().timeIntervalSince(lastSpoke) > 2 else { return }
        switch z {
        case .danger: say("停，前面很近")
        case .warn: say(String(format: "前方%.0f米有障碍", max(1, distance.rounded())))
        case .clear: say("前面通了")
        case .off: break
        }
    }

    private func say(_ text: String) {
        lastSpoke = Date()
        LocalVoice.say(text)   // 和读字/找东西共用一个播报口，新话顶旧话，不互相叠音
    }
}
