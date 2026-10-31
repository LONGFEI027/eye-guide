import Foundation

enum Config {
    /// 服务端：直接用茉兔的线上服务器（账号、实时桥、计费都是现成的）。
    /// 本机开发时可改成 http://192.168.x.x:8321 + ws://192.168.x.x:8322。
    static let apiBase = URL(string: "https://www.feizhu.asia")!
    static let realtimeURL = URL(string: "wss://www.feizhu.asia/realtime?model=qwen3.8-omni-flash-realtime")!
    /// 音色：Serena 苏瑶（温柔清晰，适合长时间听）——试音了 Ono Anna、Cici 后还是选回它
    static let voice = "Serena"
}
