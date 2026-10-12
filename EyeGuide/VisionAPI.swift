import Foundation

/// 视觉模型（服务器 /api/vision → 百炼 qwen-vl）：look_closely 的高清细看。
/// 用登录 Cookie 认证、记在同一个账户用量里。
enum VisionAPI {
    static func ask(_ jpeg: Data, prompt: String) async -> String? {
        var req = URLRequest(url: Config.apiBase.appendingPathComponent("api/vision"))
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "image": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "prompt": prompt])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 替视障用户仔细看一张照片：逐字读文字、不编造、看不清就说看不清
    static func inspect(_ jpeg: Data, question: String) async -> String? {
        await ask(jpeg, prompt: """
        你是视障人士的视觉助手，这张照片来自他手机的后置摄像头。他想知道：\(question)。
        只说和问题相关的内容；读文字必须逐字准确，模糊或被遮挡就直说哪部分看不清，绝不编造或猜测；\
        方位用"画面左边/右边/中间"描述。不超过80个字，口语化，直接说结论。
        """)
    }
}
