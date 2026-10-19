//
//  RGCxrAuthManager.swift
//  RGCxrServer
//
//  Created by Ginger on 2026/1/13.
//

import Foundation
import RGCoreKit
import Combine

// MARK: - 鉴权请求
public struct RGCxrAuthRequest: Codable {
    public let version: String?      // 版本号
    public let scopes: [String]      // 申请的能力权限
    public let appName: String?      // 应用名称
    public let bundleId: String      // 包名
    public let appIcon: Data?        // 应用头像
    
    
    public init(version: String?, scopes: [String], appName: String?, bundleId: String, appIcon: Data?) {
        self.bundleId = bundleId
        self.appName = appName
        self.version = version
        self.scopes = scopes
        self.appIcon = appIcon
    }
}

// MARK: - 鉴权信息
internal struct RGCxrAuthInfo: Codable {
    internal let bundleId: String
    internal let appName: String?
    internal let token: String
    internal let authorizedAt: TimeInterval
    internal let expiresAt: TimeInterval?
    internal let scopes: [String]
    
    internal var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date().timeIntervalSince1970 > expiresAt
    }
    
    internal func hasSameScopes(_ scopes: [String]) -> Bool {
        return Set(self.scopes) == Set(scopes)
    }
}

// MARK: - 鉴权事件
internal enum RGCxrAuthEvent {
    case authorizationRequired(request: RGCxrAuthRequest, completion: (Bool) -> Void)
    case authorized(bundleId: String, token: String)
    case denied(bundleId: String, error: String)
    case expired(bundleId: String)
}

// MARK: - URL Scheme 参数
internal struct RGCxrAuthURLParams {
    internal let bundleId: String
    internal let scopes: [String]
    internal let nonce: String
    internal let timestamp: TimeInterval
    internal let callback: String
    internal let appName: String?
    internal let version: String?
}

// MARK: - 鉴权配置
internal struct RGCxrAuthConfig {
    internal var serverScheme: String
    internal var serverHost: String
    internal var timestampTolerance: TimeInterval
    
    internal init(
        serverScheme: String = "rokidai",
        serverHost: String = "connect",
        timestampTolerance: TimeInterval = 300.0
    ) {
        self.serverScheme = serverScheme
        self.serverHost = serverHost
        self.timestampTolerance = timestampTolerance
    }
}

// MARK: - 鉴权管理器
internal final class RGCxrAuthManager {
    
    internal static let shared = RGCxrAuthManager()
    
    internal var config: RGCxrAuthConfig = RGCxrAuthConfig()
    
    internal var activeDeviceNameProvider: (() -> String?)?
    
    private let eventSubject = PassthroughSubject<RGCxrAuthEvent, Never>()
    internal var eventPublisher: AnyPublisher<RGCxrAuthEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }
    
    private var authorizedApps: [String: RGCxrAuthInfo] = [:]
    private let lock = NSLock()
    
    internal var defaultTokenExpiration: TimeInterval? = nil
    
    private var pendingCallbacks: [String: String] = [:]
    
    private init() {
        loadAuthInfo()
    }
    
    // MARK: - URL Scheme 处理
    
    internal func handleURLScheme(_ url: URL) -> Bool {
        guard url.scheme == config.serverScheme,
              url.host == config.serverHost else {
            RGLog.debug("[AuthManager] URL 不匹配: \(url.absoluteString)")
            return false
        }
        
        RGLog.info("[AuthManager] 收到鉴权请求: \(url.absoluteString)")
        
        let params = parseURLParams(url)
        
        guard validateURLParams(params) else {
            return false
        }
        
        let authURLParams = RGCxrAuthURLParams(
            bundleId: params["bundleId"] ?? "",
            scopes: params["scopes"]?.components(separatedBy: ",") ?? [],
            nonce: params["nonce"] ?? "",
            timestamp: Double(params["timestamp"] ?? "") ?? 0,
            callback: params["callback"] ?? "",
            appName: params["appName"],
            version: params["version"]
        )
        
        storeCallback(authURLParams.callback, for: authURLParams.nonce)
        
        let authRequest = RGCxrAuthRequest(
            version: authURLParams.version,
            scopes: authURLParams.scopes,
            appName: authURLParams.appName,
            bundleId: authURLParams.bundleId,
            appIcon: nil
        )
        
        handleAuthRequest(authRequest) { [weak self] response in
            self?.handleAuthResponse(response, callback: authURLParams.callback, bundleId: authURLParams.bundleId)
        }
        
        return true
    }
    
    internal func canHandleURL(_ url: URL) -> Bool {
        return url.scheme == config.serverScheme && url.host == config.serverHost
    }
    
    // MARK: - 鉴权请求处理
    
    internal func handleAuthRequest(_ request: RGCxrAuthRequest, completion: @escaping (RGCxrAuthResponse) -> Void) {
        let bundleId = request.bundleId
        
        if let existingAuth = getAuthInfo(for: bundleId) {
            if !existingAuth.isExpired {
                if existingAuth.hasSameScopes(request.scopes) {
                    RGLog.info("[AuthManager] 应用 \(bundleId) 已存在有效鉴权，直接返回成功")
                    let response = RGCxrAuthResponse(
                        status: .authorized,
                        token: existingAuth.token,
                        message: "Already authorized",
                        expiresAt: existingAuth.expiresAt
                    )
                    eventSubject.send(.authorized(bundleId: bundleId, token: existingAuth.token))
                    completion(response)
                    return
                } else {
                    RGLog.info("[AuthManager] 应用 \(bundleId) scopes 变化，需要重新授权")
                    removeAuthInfo(for: bundleId)
                }
            } else {
                RGLog.info("[AuthManager] 应用 \(bundleId) 鉴权已过期，移除旧信息")
                removeAuthInfo(for: bundleId)
                eventSubject.send(.expired(bundleId: bundleId))
            }
        }
        
        RGLog.info("[AuthManager] 应用 \(bundleId) 需要重新授权，上报到外层")
        eventSubject.send(.authorizationRequired(request: request) { [weak self] approved in
            guard let self = self else { return }
            
            if approved {
                RGLog.info("[AuthManager] 应用 \(bundleId) 外层鉴权通过")
                let response = self.authorizeApp(request)
                completion(response)
            } else {
                RGLog.info("[AuthManager] 应用 \(bundleId) 外层鉴权被拒绝")
                self.eventSubject.send(.denied(bundleId: bundleId, error: "denied"))
                let response = RGCxrAuthResponse(
                    status: .denied,
                    token: nil,
                    message: "Authorization denied by user"
                )
                completion(response)
            }
        })
    }
    
    internal func validateToken(_ token: String, for bundleId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let authInfo = authorizedApps[bundleId] else { return false }
        return authInfo.token == token && !authInfo.isExpired
    }
    
    internal func revokeAuthorization(for bundleId: String) {
        removeAuthInfo(for: bundleId)
        RGLog.info("[AuthManager] 已撤销应用 \(bundleId) 的授权")
    }
    
    internal func revokeAllAuthorizations() {
        lock.lock()
        let count = authorizedApps.count
        authorizedApps.removeAll()
        lock.unlock()
        persistAuthInfo()
        RGLog.info("[AuthManager] 已撤销全部授权，数量: \(count)")
    }
    
    internal func getAllAuthorizedApps() -> [RGCxrAuthInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(authorizedApps.values)
    }
    
    // MARK: - Private Methods
    
    private func authorizeApp(_ request: RGCxrAuthRequest) -> RGCxrAuthResponse {
        let token = generateToken()
        let now = Date().timeIntervalSince1970
        let expiresAt: TimeInterval? = defaultTokenExpiration
        
        let authInfo = RGCxrAuthInfo(
            bundleId: request.bundleId,
            appName: request.appName,
            token: token,
            authorizedAt: now,
            expiresAt: expiresAt,
            scopes: request.scopes
        )
        
        saveAuthInfo(authInfo)
        RGLog.info("[AuthManager] 应用 \(request.bundleId) 授权成功")
        eventSubject.send(.authorized(bundleId: request.bundleId, token: token))
        
        return RGCxrAuthResponse(
            status: .authorized,
            token: token,
            message: "Authorization granted",
            expiresAt: expiresAt
        )
    }
    
    private func generateToken() -> String {
        UUID().uuidString + "-" + String(Int(Date().timeIntervalSince1970))
    }
    
    private func getAuthInfo(for bundleId: String) -> RGCxrAuthInfo? {
        lock.lock()
        defer { lock.unlock() }
        return authorizedApps[bundleId]
    }
    
    private func saveAuthInfo(_ info: RGCxrAuthInfo) {
        lock.lock()
        authorizedApps[info.bundleId] = info
        lock.unlock()
        persistAuthInfo()
    }
    
    private func removeAuthInfo(for bundleId: String) {
        lock.lock()
        authorizedApps.removeValue(forKey: bundleId)
        lock.unlock()
        persistAuthInfo()
    }
    
    // MARK: - URL Scheme Helpers
    
    private func parseURLParams(_ url: URL) -> [String: String] {
        var params: [String: String] = [:]
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return params
        }
        
        for item in queryItems {
            params[item.name] = item.value
        }
        
        return params
    }
    
    private func validateURLParams(_ params: [String: String]) -> Bool {
        guard let bundleId = params["bundleId"], !bundleId.isEmpty else {
            RGLog.error("[AuthManager] 缺少 bundleId")
            sendErrorCallback(callback: params["callback"], error: "missing_bundle_id")
            return false
        }
        
        guard let scopes = params["scopes"], !scopes.isEmpty else {
            RGLog.error("[AuthManager] 缺少 scopes")
            sendErrorCallback(callback: params["callback"], error: "missing_scopes")
            return false
        }
        
        guard let nonce = params["nonce"], !nonce.isEmpty else {
            RGLog.error("[AuthManager] 缺少 nonce")
            sendErrorCallback(callback: params["callback"], error: "missing_nonce")
            return false
        }
        
        guard let timestampStr = params["timestamp"],
              let timestamp = Double(timestampStr) else {
            RGLog.error("[AuthManager] 缺少或无效的 timestamp")
            sendErrorCallback(callback: params["callback"], error: "missing_timestamp")
            return false
        }
        
        let now = Date().timeIntervalSince1970
        let elapsed = abs(now - timestamp)
        if elapsed > config.timestampTolerance {
            RGLog.error("[AuthManager] 时间戳过期，elapsed: \(elapsed)s")
            sendErrorCallback(callback: params["callback"], error: "timestamp_expired")
            return false
        }
        
        guard let callback = params["callback"], !callback.isEmpty else {
            RGLog.error("[AuthManager] 缺少 callback")
            return false
        }
        
        return true
    }
    
    private func handleAuthResponse(_ response: RGCxrAuthResponse, callback: String, bundleId: String) {
        switch response.status {
        case .authorized:
            guard let token = response.token else {
                RGLog.error("[AuthManager] 鉴权成功但缺少 token")
                sendErrorCallback(callback: callback, error: "missing_token")
                return
            }
            
            sendSuccessCallback(callback: callback, token: token, expiresAt: response.expiresAt)
            
        case .denied:
            sendErrorCallback(callback: callback, error: response.message ?? "auth_denied")
            
        case .expired:
            sendErrorCallback(callback: callback, error: "auth_expired")
            
        case .pending:
            RGLog.info("[AuthManager] 鉴权等待中，需要用户确认")
        }
    }
    
    private func sendSuccessCallback(callback: String, token: String, expiresAt: TimeInterval?) {
        guard var components = URLComponents(string: callback) else {
            RGLog.error("[AuthManager] 无效的 callback URL: \(callback)")
            return
        }
        
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "success", value: "true"),
            URLQueryItem(name: "token", value: token)
        ]
        
        if let expiresAt = expiresAt {
            queryItems.append(URLQueryItem(name: "expiresAt", value: String(Int(expiresAt))))
        }
        
        if let deviceName = activeDeviceNameProvider?() {
            queryItems.append(URLQueryItem(name: "deviceName", value: deviceName))
            RGLog.info("[AuthManager] 添加活跃设备名到回调: \(deviceName)")
        }
        
        components.queryItems = queryItems
        
        guard let callbackURL = components.url else {
            RGLog.error("[AuthManager] 无法构建 callback URL")
            return
        }
        
        RGLog.info("[AuthManager] 发送成功回调: \(callbackURL.absoluteString)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if UIApplication.shared.canOpenURL(callbackURL) {
                UIApplication.shared.open(callbackURL) { success in
                    RGLog.info(success ? "[AuthManager] 成功打开回调应用" : "[AuthManager] 打开回调应用失败")
                }
            } else {
                RGLog.error("[AuthManager] 无法打开回调 URL: \(callbackURL.absoluteString)")
            }
        }
    }
    
    private func sendErrorCallback(callback: String?, error: String) {
        guard let callback = callback, !callback.isEmpty,
              var components = URLComponents(string: callback) else {
            RGLog.error("[AuthManager] 无法发送错误回调，callback 无效")
            return
        }
        
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "success", value: "false"),
            URLQueryItem(name: "error", value: error)
        ]
        
        components.queryItems = queryItems
        
        guard let callbackURL = components.url else {
            RGLog.error("[AuthManager] 无法构建错误回调 URL")
            return
        }
        
        RGLog.info("[AuthManager] 发送错误回调: \(callbackURL.absoluteString)")
        
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(callbackURL) {
                UIApplication.shared.open(callbackURL)
            }
        }
    }
    
    private func storeCallback(_ callback: String, for nonce: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingCallbacks[nonce] = callback
    }
    
    // MARK: - Persistence
    
    private var authInfoPath: String {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return (documentsPath as NSString).appendingPathComponent("RGCxrAuthInfo.plist")
    }
    
    private func loadAuthInfo() {
        guard FileManager.default.fileExists(atPath: authInfoPath),
              let data = FileManager.default.contents(atPath: authInfoPath),
              let infos = try? PropertyListDecoder().decode([String: RGCxrAuthInfo].self, from: data) else {
            return
        }
        
        lock.lock()
        authorizedApps = infos
        lock.unlock()
        
        let expiredBundleIds = infos.filter { $0.value.isExpired }.map { $0.key }
        for bundleId in expiredBundleIds {
            removeAuthInfo(for: bundleId)
        }
        
        RGLog.info("[AuthManager] 已加载 \(authorizedApps.count) 条鉴权信息")
    }
    
    private func persistAuthInfo() {
        lock.lock()
        let infos = authorizedApps
        lock.unlock()
        
        guard let data = try? PropertyListEncoder().encode(infos) else { return }
        try? data.write(to: URL(fileURLWithPath: authInfoPath))
    }
}
