import Foundation
import AVFoundation

/// 工作模式（学 Seeing AI 的频道化设计）：不同任务不同交互节奏，她通过 set_mode 工具切换。
enum GuideMode: String {
    case chat   // 自由问答（默认）
    case walk   // 行走护送：她当安静的护送员，重要路况才开口
    case read   // 读字：App 本地即时朗读（不经过大模型）
    case find   // 找东西：App 本地检测目标报钟面方向

    var name: String {
        switch self {
        case .chat: return "聊天"
        case .walk: return "行走"
        case .read: return "读字"
        case .find: return "找东西"
        }
    }
}

/// 本地即时播报（系统 TTS，和大模型的声音各管各的；读字/找东西两个本地通道用它）
@MainActor
enum LocalVoice {
    private static let synth = AVSpeechSynthesizer()

    static func say(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.55
        synth.speak(u)
    }

    static func hush() { synth.stopSpeaking(at: .immediate) }
}
