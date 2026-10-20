import Foundation
import UIKit
import AVFoundation

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

    private let haptic = UIImpactFeedbackGenerator(style: .heavy)
    private let speech = AVSpeechSynthesizer()
    private var hapticTimer: Timer?
    private var lastSpoke = Date.distantPast
    private var lastZoneChange = Date.distantPast

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
            haptic.prepare()
            zone = .clear
            say("护航已开启")
        } else {
            zone = .off
            hapticTimer?.invalidate(); hapticTimer = nil
            say("护航已关闭")
        }
    }

    /// 震动节奏：危险 0.18s 一下，注意 0.55s 一下，畅通不震
    private func retune() {
        hapticTimer?.invalidate(); hapticTimer = nil
        let interval: TimeInterval
        switch zone {
        case .danger: interval = 0.18
        case .warn: interval = 0.55
        default: return
        }
        hapticTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                self.haptic.impactOccurred(intensity: self.zone == .danger ? 1.0 : 0.7)
            }
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
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.55
        speech.speak(u)
    }
}
