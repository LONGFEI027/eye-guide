//
//  RGCxrClientAuthManager.swift
//  RGCxrClient
//
//  Created by Ginger on 2026/3/2.
//

import Foundation
import Combine
import RGCoreKit

public enum RGCxrClientAuthState {
    case notAuthenticated
    case authenticating
    case authenticated(token: String, expiresAt: TimeInterval?)
    case expired
    case failed(error: String)
    
    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

public enum RGCxrClientAuthEvent {
    case stateChanged(RGCxrClientAuthState)
    case authenticationSucceeded(token: String, sessionId: String?, deviceName: String?)
    case authenticationFailed(error: String)
    case tokenExpired
}

public struct RGCxrClientAuthConfig {
    public var serverScheme: String
    public var serverHost: String
    public var callbackScheme: String
    public var callbackHost: String
    public var callbackPath: String
    public var requestTimeout: TimeInterval
    public var timestampTolerance: TimeInterval
    
    public init(
        serverScheme: String = "rokidai",
        serverHost: String = "connect",
        callbackScheme: String = "cxrl",
        callbackHost: String = "auth",
        callbackPath: String = "/callback",
        requestTimeout: TimeInterval = 60.0,
        timestampTolerance: TimeInterval = 300.0
    ) {
        self.serverScheme = serverScheme
        self.serverHost = serverHost
        self.callbackScheme = callbackScheme
        self.callbackHost = callbackHost
        self.callbackPath = callbackPath
        self.requestTimeout = requestTimeout
        self.timestampTolerance = timestampTolerance
    }
}

public enum RGCxrClientAuthPermission: String {
    case microphone
    case camera
    case media
}

public final class RGCxrClientAuthManager {

    public static let shared = RGCxrClientAuthManager()

    private var _config = RGCxrClientAuthConfig()
    public var config: RGCxrClientAuthConfig {
        get {
            guard RGCxrClientLifecycle.isInitialized else {
                RGLog.error("[CxrClientAuth] 读取 config 前须先调用 CxrClient.initialize")
                return RGCxrClientAuthConfig()
            }
            return _config
        }
        set {
            guard RGCxrClientLifecycle.isInitialized else {
                RGLog.error("[CxrClientAuth] 写入 config 前须先调用 CxrClient.initialize")
                return
            }
            _config = newValue
        }
    }

    private let eventSubject = PassthroughSubject<RGCxrClientAuthEvent, Never>()
    public var eventPublisher: AnyPublisher<RGCxrClientAuthEvent, Never> {
        eventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in ready }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    private let stateSubject = CurrentValueSubject<RGCxrClientAuthState, Never>(.notAuthenticated)
    public var statePublisher: AnyPublisher<RGCxrClientAuthState, Never> {
        stateSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in ready }
            .map { state, _ in state }
            .eraseToAnyPublisher()
    }
    

    private func ensureClientInitialized(_ member: String = #function) -> Bool {
        guard RGCxrClientLifecycle.isInitialized else {
            RGLog.error("[CxrClientAuth] 须先调用 CxrClient.initialize，已忽略: \(member)")
            return false
        }
        return true
    }
    
    public private(set) var currentState: RGCxrClientAuthState {
        get { stateSubject.value }
        set {
            stateSubject.send(newValue)
            eventSubject.send(.stateChanged(newValue))
        }
    }
    
    public private(set) var currentToken: String?
    public private(set) var currentSessionId: String?
    public private(set) var currentDeviceName: String?
    public private(set) var expiresAt: TimeInterval?
    /// 本次鉴权成功后眼镜端授予的权限集合；`clearAuthentication` 或 token 过期后会被清空。
    public private(set) var grantedScopes: Set<RGCxrClientAuthPermission> = []
    
    private var usedNonces: Set<String> = []
    private let nonceLock = NSLock()
    private var pendingAuthRequest: PendingAuthRequest?
    private var authTimeoutTimer: Timer?
    
    private let lock = NSLock()
    
    private struct PendingAuthRequest {
        let nonce: String
        let timestamp: TimeInterval
        let scopes: [String]
        let completion: ((Result<(token: String, sessionId: String?), Error>) -> Void)?
    }
    
    private init() {
        cleanExpiredNonces()
    }
    
    public func authenticate(
        scopes: [RGCxrClientAuthPermission],
        bundleId: String? = nil,
        appName: String? = nil,
        completion: ((Result<(token: String, sessionId: String?), Error>) -> Void)? = nil
    ) {
        guard ensureClientInitialized() else {
            let err = NSError(
                domain: "RGCxrClientAuthError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "SDK 未初始化，请先调用 CxrClient.initialize"]
            )
            completion?(.failure(err))
            return
        }
        guard let snap = RGCxrClientLifecycle.snapshot else {
            let err = NSError(
                domain: "RGCxrClientAuthError",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "SDK 初始化状态异常"]
            )
            completion?(.failure(err))
            return
        }

        let bundleId = bundleId ?? Bundle.main.bundleIdentifier ?? "com.rokid.cxrl"
        let appName = appName ?? snap.options.appDisplayName
        
        if let existingToken = currentToken, let existingExpires = expiresAt {
            if Date().timeIntervalSince1970 < existingExpires {
                RGLog.info("[CxrClientAuth] 已存在有效的鉴权 token，无需重新鉴权")
                completion?(.success((token: existingToken, sessionId: currentSessionId)))
                return
            } else {
                RGLog.info("[CxrClientAuth] 鉴权已过期，需要重新鉴权")
                currentState = .expired
                eventSubject.send(.tokenExpired)
            }
        }
        
        let nonce = generateNonce()
        let timestamp = Date().timeIntervalSince1970
        
        storeNonce(nonce)

        let uniqueScopes: [RGCxrClientAuthPermission] = {
            var seen = Set<RGCxrClientAuthPermission>()
            return scopes.filter { seen.insert($0).inserted }
        }()
        
        pendingAuthRequest = PendingAuthRequest(
            nonce: nonce,
            timestamp: timestamp,
            scopes: uniqueScopes.map({ $0.rawValue }),
            completion: completion
        )
        
        currentState = .authenticating
        
        let authURL = buildAuthURL(
            bundleId: bundleId,
            scopes: uniqueScopes.map({ $0.rawValue }),
            nonce: nonce,
            timestamp: timestamp,
            appName: appName
        )
        
        guard let url = authURL else {
            let error = "无法构建鉴权 URL"
            RGLog.error("[CxrClientAuth] \(error)")
            handleAuthFailure(error: error)
            return
        }
        
        RGLog.info("[CxrClientAuth] 发起鉴权请求: \(url.absoluteString)")
        
        startAuthTimeoutTimer()
        
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url) { [weak self] success in
                    if !success {
                        let error = "无法打开 Rokid AI 应用"
                        RGLog.error("[CxrClientAuth] \(error)")
                        self?.handleAuthFailure(error: error)
                    } else {
                        RGLog.info("[CxrClientAuth] 已打开 Rokid AI 应用等待鉴权回调")
                    }
                }
            } else {
                let error = "Rokid AI 应用未安装"
                RGLog.error("[CxrClientAuth] \(error)")
                self.handleAuthFailure(error: error)
            }
        }
    }
    
    public func handleCallback(url: URL) -> Bool {
        guard ensureClientInitialized() else { return false }
        guard url.scheme == _config.callbackScheme,
              url.host == _config.callbackHost,
              url.path == _config.callbackPath else {
            RGLog.debug("[CxrClientAuth] URL 不匹配回调格式: \(url.absoluteString)")
            return false
        }
        
        RGLog.info("[CxrClientAuth] 收到鉴权回调: \(url.absoluteString)")
        
        let params = parseURLParams(url)
        
        guard let pendingRequest = pendingAuthRequest else {
            RGLog.warn("[CxrClientAuth] 没有待处理的鉴权请求")
            return true
        }
        
        guard validateCallback(params: params, pendingRequest: pendingRequest) else {
            handleAuthFailure(error: "鉴权回调验证失败")
            return true
        }
        
        cancelAuthTimeoutTimer()
        
        if let success = params["success"], success == "true" || success == "1" {
            handleAuthSuccess(params: params, pendingRequest: pendingRequest)
        } else {
            let error = params["error"] ?? params["message"] ?? "鉴权失败"
            handleAuthFailure(error: error)
        }
        
        pendingAuthRequest = nil
        cleanExpiredNonces()
        
        return true
    }
    
    public func isAuthenticated() -> Bool {
        guard RGCxrClientLifecycle.isInitialized else { return false }
        guard let token = currentToken else { return false }
        
        if let expiresAt = expiresAt {
            return Date().timeIntervalSince1970 < expiresAt
        }
        
        return true
    }

    /// 判断当前鉴权是否已授予指定权限；未完成鉴权或 token 已过期时返回 `false`。
    public func hasPermission(_ permission: RGCxrClientAuthPermission) -> Bool {
        guard isAuthenticated() else { return false }
        return grantedScopes.contains(permission)
    }
    
    public func getCurrentToken() -> String? {
        guard isAuthenticated() else { return nil }
        return currentToken
    }
    
    public func getCurrentSessionId() -> String? {
        guard isAuthenticated() else { return nil }
        return currentSessionId
    }
    
    public func getCurrentDeviceName() -> String? {
        guard isAuthenticated() else { return nil }
        return currentDeviceName
    }
    
    public func clearAuthentication() {
        guard ensureClientInitialized() else { return }
        lock.lock()
        currentToken = nil
        currentSessionId = nil
        currentDeviceName = nil
        expiresAt = nil
        grantedScopes = []
        lock.unlock()
        
        currentState = .notAuthenticated
        RGLog.info("[CxrClientAuth] 已清除鉴权信息")
    }
    
    public func refreshToken(
        scopes: [RGCxrClientAuthPermission]? = nil,
        completion: ((Result<(token: String, sessionId: String?), Error>) -> Void)? = nil
    ) {
        guard ensureClientInitialized() else {
            let err = NSError(
                domain: "RGCxrClientAuthError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "SDK 未初始化，请先调用 CxrClient.initialize"]
            )
            completion?(.failure(err))
            return
        }
        RGLog.info("[CxrClientAuth] 开始刷新 token")
        
        let scopes = scopes ?? pendingAuthRequest?.scopes.map({RGCxrClientAuthPermission(rawValue: $0) ?? .media})
        
        authenticate(scopes: scopes ?? [], completion: completion)
    }
    
    private func buildAuthURL(
        bundleId: String,
        scopes: [String],
        nonce: String,
        timestamp: TimeInterval,
        appName: String?
    ) -> URL? {
        var components = URLComponents()
        components.scheme = _config.serverScheme
        components.host = _config.serverHost
        
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "bundleId", value: bundleId),
            URLQueryItem(name: "scopes", value: scopes.joined(separator: ",")),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "timestamp", value: String(Int(timestamp))),
            URLQueryItem(name: "callback", value: buildCallbackURL())
        ]
        
        if let appName = appName {
            queryItems.append(URLQueryItem(name: "appName", value: appName))
        }
        
        components.queryItems = queryItems
        
        return components.url
    }
    
    private func buildCallbackURL() -> String {
        var components = URLComponents()
        components.scheme = _config.callbackScheme
        components.host = _config.callbackHost
        components.path = _config.callbackPath
        return components.url?.absoluteString ?? "\(_config.callbackScheme)://\(_config.callbackHost)\(_config.callbackPath)"
    }
    
    private func parseURLParams(_ url: URL) -> [String: String] {
        var params: [String: String] = [:]
        
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems {
                params[item.name] = item.value
            }
        }
        
        return params
    }
    
    private func validateCallback(
        params: [String: String],
        pendingRequest: PendingAuthRequest
    ) -> Bool {
        if let callbackNonce = params["nonce"], callbackNonce != pendingRequest.nonce {
            RGLog.warn("[CxrClientAuth] nonce 不匹配: 收到 \(callbackNonce), 期望 \(pendingRequest.nonce)")
            return false
        }
        
        if !isNonceValid(pendingRequest.nonce) {
            RGLog.warn("[CxrClientAuth] nonce 已过期或不存在")
            return false
        }
        
        return true
    }
    
    private func handleAuthSuccess(
        params: [String: String],
        pendingRequest: PendingAuthRequest
    ) {
        guard let token = params["token"] else {
            handleAuthFailure(error: "鉴权成功但未返回 token")
            return
        }
        
        let sessionId = params["sessionId"]
        let deviceName = params["deviceName"]
        let expiresAt: TimeInterval? = {
            if let expiresStr = params["expiresAt"], let expires = TimeInterval(expiresStr) {
                return expires
            }
            return nil
        }()
        
        let grantedSet: Set<RGCxrClientAuthPermission> = {
            if let granted = params["scopes"]?.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }), !granted.isEmpty {
                return Set(granted.compactMap { RGCxrClientAuthPermission(rawValue: $0) })
            }
            return Set(pendingRequest.scopes.compactMap { RGCxrClientAuthPermission(rawValue: $0) })
        }()

        lock.lock()
        currentToken = token
        currentSessionId = sessionId
        currentDeviceName = deviceName
        self.expiresAt = expiresAt
        grantedScopes = grantedSet
        lock.unlock()
        
        currentState = .authenticated(token: token, expiresAt: expiresAt)
        eventSubject.send(.authenticationSucceeded(token: token, sessionId: sessionId, deviceName: deviceName))
        
        RGLog.info("[CxrClientAuth] 鉴权成功, token: \(token.prefix(8))..., sessionId: \(sessionId ?? "nil"), deviceName: \(deviceName ?? "nil")")
        
        pendingRequest.completion?(.success((token: token, sessionId: sessionId)))
    }
    
    private func handleAuthFailure(error: String) {
        cancelAuthTimeoutTimer()
        
        currentState = .failed(error: error)
        eventSubject.send(.authenticationFailed(error: error))
        
        RGLog.error("[CxrClientAuth] 鉴权失败: \(error)")
        
        pendingAuthRequest?.completion?(.failure(NSError(
            domain: "RGCxrClientAuthError",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: error]
        )))
        
        pendingAuthRequest = nil
    }
    
    private func generateNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    
    private func storeNonce(_ nonce: String) {
        nonceLock.lock()
        defer { nonceLock.unlock() }
        
        usedNonces.insert(nonce)
        
        RGLog.debug("[CxrClientAuth] 存储 nonce: \(nonce)")
    }
    
    private func isNonceValid(_ nonce: String) -> Bool {
        nonceLock.lock()
        defer { nonceLock.unlock() }
        
        return usedNonces.contains(nonce)
    }
    
    private func cleanExpiredNonces() {
        nonceLock.lock()
        defer { nonceLock.unlock() }
        
        if usedNonces.count > 100 {
            usedNonces.removeAll()
            RGLog.debug("[CxrClientAuth] 清理所有 nonce 缓存")
        }
    }
    
    private func startAuthTimeoutTimer() {
        cancelAuthTimeoutTimer()
        
        authTimeoutTimer = Timer.scheduledTimer(withTimeInterval: _config.requestTimeout, repeats: false) { [weak self] _ in
            self?.handleAuthTimeout()
        }
        
        if let timer = authTimeoutTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func cancelAuthTimeoutTimer() {
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = nil
    }
    
    private func handleAuthTimeout() {
        guard pendingAuthRequest != nil else { return }
        
        RGLog.warn("[CxrClientAuth] 鉴权请求超时")
        handleAuthFailure(error: "鉴权请求超时")
    }
}

public extension RGCxrClientAuthManager {

    func canHandleURL(_ url: URL) -> Bool {
        guard RGCxrClientLifecycle.isInitialized else { return false }
        return url.scheme == _config.callbackScheme &&
               url.host == _config.callbackHost &&
               url.path == _config.callbackPath
    }
}
