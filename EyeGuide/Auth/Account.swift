import Foundation

/// 账号：登录茉兔服务器拿会话 Cookie。
/// Cookie 存在系统的 HTTPCookieStorage 里（自动持久化），之后的 API 请求和
/// WebSocket 握手（同一个 URLSession）都会自动带上，不用手动管理。
@MainActor
final class Account: ObservableObject {
    @Published var login = UserDefaults.standard.string(forKey: "login") ?? ""
    @Published var needLogin = false

    func check() async {
        var req = URLRequest(url: Config.apiBase.appendingPathComponent("api/me"))
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            needLogin = (resp as? HTTPURLResponse)?.statusCode != 200
        } catch {
            needLogin = login.isEmpty   // 断网时不弹登录框（除非从没登过）
        }
    }

    func signIn(name: String, password: String) async throws {
        var req = URLRequest(url: Config.apiBase.appendingPathComponent("api/auth/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["login": name, "password": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, obj["ok"] as? Bool == true else {
            throw NSError(domain: "login", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: obj["detail"] as? String ?? "登录失败"])
        }
        login = name
        UserDefaults.standard.set(name, forKey: "login")
        needLogin = false
    }
}
