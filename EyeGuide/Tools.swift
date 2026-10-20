import Foundation

/// 小路的工具（实时模型 qwen3.8-omni-flash-realtime 的函数调用）。
/// 格式用 OpenAI Realtime 的扁平写法（photo-coach 实测比嵌套 function 写法调用更稳）。
/// 工具刻意少：越少越可靠，安全层的事一件都不交给模型。
enum Tools {
    static let schema: [[String: Any]] = [
        fn("look_closely",
           "拍一张高清照片仔细看清细节（文字、门牌、站牌、价签、远处的东西）。比你平时收到的实时画面清楚得多。调用后不要自己猜内容，等结果返回再开口。",
           ["question": ["type": "string", "description": "要看清什么，比如'读出站牌上的线路和方向'、'门上写的几单元'"]],
           required: ["question"]),
        fn("set_zoom",
           "切换镜头焦段看远近：3=看远处细节（站牌、路牌），2=稍远，1=正常走路视野，0.5=超广角看全景。看完远处记得调回1。",
           ["lens": ["type": "string", "enum": ["0.5", "1", "2", "3"]]], required: ["lens"]),
        fn("set_torch",
           "手电筒：画面太暗看不清时打开，离开暗处记得关掉",
           ["on": ["type": "boolean"]], required: ["on"]),
        fn("set_mode",
           "切换工作模式。walk=行走护送（对方说'陪我走/带我走'时用，你变成安静的护送员，只报重要路况）；read=读字（对方说'帮我读/扫一下文字'时用，App会本地即时朗读看到的文字）；find=找东西（对方说'帮我找XX'时用，必须填target，App本地检测到会直接报方向）；chat=回到自由问答（对方说'到了/不找了/退出'时用）。",
           ["mode": ["type": "string", "enum": ["walk", "read", "find", "chat"]],
            "target": ["type": "string", "description": "find模式要找的东西，比如'椅子'、'我的水杯'"]],
           required: ["mode"]),
    ]

    private static func fn(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function", "name": name, "description": desc,
         "parameters": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }

    // MARK: - 参数宽松解析（快速模型偶尔不按枚举填）

    static func lens(_ v: Any?) -> String {
        let s = "\(v ?? "")".lowercased()
        if s.contains("0.5") || s.contains("广") || s.contains("wide") { return "0.5" }
        if s.contains("3") || s.contains("远") || s.contains("tele") { return "3" }
        if s.contains("2") { return "2" }
        return "1"
    }

    static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        let s = "\(v ?? "")".lowercased()
        return s.contains("true") || s.contains("on") || s.contains("开") || s == "1"
    }

    static func mode(_ v: Any?) -> GuideMode {
        let s = "\(v ?? "")".lowercased()
        if s.contains("walk") || s.contains("行走") || s.contains("走") { return .walk }
        if s.contains("read") || s.contains("读") { return .read }
        if s.contains("find") || s.contains("找") { return .find }
        return .chat
    }
}
