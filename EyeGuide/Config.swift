import Foundation

enum Config {
    /// 服务端：直接用茉兔的线上服务器（账号、实时桥、计费都是现成的）。
    /// 本机开发时可改成 http://192.168.x.x:8321 + ws://192.168.x.x:8322。
    static let apiBase = URL(string: "https://www.feizhu.asia")!
    static let realtimeURL = URL(string: "wss://www.feizhu.asia/realtime?model=qwen3.8-omni-flash-realtime")!
    /// 音色：Serena（温柔清晰的女声，适合长时间听）
    static let voice = "Serena"
}
