//
//  RGCxrClientImpl.swift
//  Pods
//
//  Created by Ginger on 2026/3/4.
//

import Foundation
import Combine
import RGCoreKit

internal final class RGCxrClientImpl: RGCxrClient {
    let ble: RGCxrClientBLE = .shared
    let auth: RGCxrClientAuthManager = .shared
    private let audioEventSubject = PassthroughSubject<RGCxrClientAudioEvent, Never>()
    private let customViewRunningEventSubject = PassthroughSubject<RGCxrClientCustomViewRunningEvent, Never>()
    private let appResumeChangeEventSubject = PassthroughSubject<RGCxrClientAppResumeChangeEvent, Never>()
    private let notifyEventSubject = PassthroughSubject<RGCxrClientNotifyEvent, Never>()
    private let deviceInfoEventSubject = PassthroughSubject<RGCxrDeviceInfo, Never>()
    private let wearingStatusEventSubject = PassthroughSubject<Bool, Never>()
    private let aiWakeInterruptEventSubject = PassthroughSubject<Bool, Never>()
    private let sessionStateStore = RGCxrSessionStateStore.shared

    private enum ThirdAppRequestKind {
        case queryApp, openApp, stopApp, uninstallApp, installApp
    }

    private var pendingThirdAppRequestKinds: [Int: ThirdAppRequestKind] = [:]
    private let preconditionLock = NSLock()
    /// 眼镜上报的自定义 View 是否处于运行中（`customViewRunningStatus`）。
    private var isCustomViewRunning: Bool = false
    /// `appResumeChange` 中 `packageName` 与初始化 `pageName` 一致，视为目标三方应用在前台。
    private var targetAppResumeMatchesPage: Bool = false
    /// 最近一次 `openApp` 协议回调为成功；`stopApp` / `uninstallApp` 成功后会清除。
    private var openAppSucceeded: Bool = false
    /// 允许透出的 notify cmd 白名单；为空表示不透出任何 notify。
    private var notifyListenCmds: Set<String> = []

    /// GATT 消息中的 `bundleId`，与历史行为一致：始终为 `Bundle.main.bundleIdentifier`（缺省为 `com.rokid.cxrl`）。
    private var gattHostBundleId: String {
        Bundle.main.bundleIdentifier ?? "com.rokid.cxrl"
    }

    func applyInitialization(mode: RGCxrClientInitMode, options: RGCxrClientInitializationOptions) {
        _ = mode
        _ = options
        preconditionLock.lock()
        isCustomViewRunning = false
        targetAppResumeMatchesPage = false
        openAppSucceeded = false
        notifyListenCmds = []
        preconditionLock.unlock()
    }

    private func ensureClientInitialized(_ member: String = #function) -> RGCxrClientError? {
        guard RGCxrClientLifecycle.isInitialized else {
            RGLog.error("[CxrClient] 须先调用 CxrClient.initialize，已忽略: \(member)")
            return .notInitialized
        }
        return nil
    }

    /// 校验调用方是否已在鉴权时获得指定权限（未鉴权/token 过期会被拒绝）。
    private func ensureAuthPermission(_ permission: RGCxrClientAuthPermission, _ member: String = #function) -> RGCxrClientError? {
        guard auth.isAuthenticated() else {
            RGLog.error("[CxrClient] \(member) 未鉴权或已过期，已忽略")
            return .notAuthenticated
        }
        guard auth.hasPermission(permission) else {
            RGLog.error("[CxrClient] \(member) 缺少鉴权权限: \(permission.rawValue)，已忽略")
            return .permissionDenied
        }
        return nil
    }

    /// `openApp` / `stopApp` / `uninstallApp` 使用的眼镜端包名，来自初始化参数 `pageName`。
    private func thirdPartyPagePackageName() -> String? {
        guard let name = RGCxrClientLifecycle.snapshot?.options.pageName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func currentInitMode() -> RGCxrClientInitMode? {
        RGCxrClientLifecycle.snapshot?.mode
    }

    private func ensureInitMode(_ expected: RGCxrClientInitMode, _ member: String = #function) -> RGCxrClientError? {
        guard let mode = currentInitMode(), mode == expected else {
            RGLog.error("[CxrClient] \(member) 要求初始化模式为 \(expected)，当前为 \(String(describing: currentInitMode()))，已忽略")
            return .modeMismatch
        }
        return nil
    }

    /// `startRecord` 等：customView 下需自定义 View 已运行；customApp 下需 `openApp` 成功或收到与 `pageName` 一致的 `appResumeChange`。
    private func ensureMediaPreconditions(_ member: String = #function) -> RGCxrClientError? {
        guard let mode = currentInitMode() else {
            RGLog.error("[CxrClient] \(member) 缺少有效初始化模式，已忽略")
            return .notReady
        }
        preconditionLock.lock()
        let running = isCustomViewRunning
        let resumeOk = targetAppResumeMatchesPage
        let openOk = openAppSucceeded
        preconditionLock.unlock()
        switch mode {
        case .customView:
            guard running else {
                RGLog.error("[CxrClient] \(member) 需先通过 openCustomView 且 customViewRunningEventPublisher 上报运行中，已忽略")
                return .notReady
            }
            return nil
        case .customApp:
            guard openOk || resumeOk else {
                RGLog.error("[CxrClient] \(member) 需先 openApp 成功，或收到 appResumeChange 且 packageName 与初始化 pageName 一致，已忽略")
                return .notReady
            }
            return nil
        }
    }

    /// `updateCustomView` / `closeCustomView`：需为 customView 且 View 已运行。
    private func ensureCustomViewRunningForMutation(_ member: String = #function) -> RGCxrClientError? {
        if let err = ensureInitMode(.customView, member) { return err }
        preconditionLock.lock()
        let running = isCustomViewRunning
        preconditionLock.unlock()
        guard running else {
            RGLog.error("[CxrClient] \(member) 需 customViewRunningEventPublisher 上报运行中，已忽略")
            return .notReady
        }
        return nil
    }

    /// `stopApp`：customApp 且须已 `openApp` 成功（与协议注释一致）。
    private func ensureOpenAppSucceededPrecondition(_ member: String = #function) -> RGCxrClientError? {
        if let err = ensureInitMode(.customApp, member) { return err }
        preconditionLock.lock()
        let ok = openAppSucceeded
        preconditionLock.unlock()
        guard ok else {
            RGLog.error("[CxrClient] \(member) 需先 openApp 成功，已忽略")
            return .notReady
        }
        return nil
    }

    /// 统一的前置条件检查入口。按顺序校验：
    /// 初始化 → 指定模式 → 鉴权/权限 → 运行时状态。
    /// - Parameters:
    ///   - requiredMode: 要求的初始化模式；传 nil 表示不限模式
    ///   - requiredPermission: 要求已鉴权并拥有该权限；传 nil 表示不校验
    ///   - requireCustomViewRunning: 是否要求当前处于 `customView` 模式且 View 已运行
    ///   - requireAppResumed: 是否要求当前处于 `customApp` 模式且 `openApp` 成功（配合 `stopApp` / `sendCustomCmd`）
    ///   - requireMediaReady: 是否要求「customView 运行中」或「customApp 已 resume」（配合音视频相关 API）
    /// - Returns: 检查失败时返回对应 `RGCxrClientError`；全部通过返回 `nil`。
    private func precheck(
        requiredMode: RGCxrClientInitMode? = nil,
        requiredPermission: RGCxrClientAuthPermission? = nil,
        requireCustomViewRunning: Bool = false,
        requireAppResumed: Bool = false,
        requireMediaReady: Bool = false,
        _ member: String = #function
    ) -> RGCxrClientError? {
        if let err = ensureClientInitialized(member) { return err }
        if let requiredMode, let err = ensureInitMode(requiredMode, member) { return err }
        if let requiredPermission, let err = ensureAuthPermission(requiredPermission, member) { return err }
        if requireCustomViewRunning, let err = ensureCustomViewRunningForMutation(member) { return err }
        if requireAppResumed, let err = ensureOpenAppSucceededPrecondition(member) { return err }
        if requireMediaReady, let err = ensureMediaPreconditions(member) { return err }
        return nil
    }

    private func logPublicCall(_ member: String, _ details: String? = nil) {
        if let details, !details.isEmpty {
            RGLog.info("[CxrClient][Public] \(member) called, \(details)")
        } else {
            RGLog.info("[CxrClient][Public] \(member) called")
        }
    }

    private func logPublicSent(_ member: String, requestId: Int? = nil, _ details: String? = nil) {
        var parts: [String] = []
        if let requestId {
            parts.append("requestId: \(requestId)")
        }
        if let details, !details.isEmpty {
            parts.append(details)
        }
        RGLog.info("[CxrClient][Public] \(member) sent\(parts.isEmpty ? "" : ", \(parts.joined(separator: ", "))")")
    }

    private func logPublicSent(_ member: String, _ details: String) {
        logPublicSent(member, requestId: nil, details)
    }

    private func logPublicCallback(_ member: String, requestId: Int? = nil, _ result: String) {
        if let requestId {
            RGLog.info("[CxrClient][Public] \(member) callback, requestId: \(requestId), \(result)")
        } else {
            RGLog.info("[CxrClient][Public] \(member) callback, \(result)")
        }
    }

    private func logPublicCallback(_ member: String, _ result: String) {
        logPublicCallback(member, requestId: nil, result)
    }

    private func logPublicEvent(_ member: String, _ details: String) {
        RGLog.info("[CxrClient][Public] \(member) event, \(details)")
    }

    private func publicMemberName(for kind: ThirdAppRequestKind?) -> String {
        switch kind {
        case .queryApp:
            return "queryApp"
        case .openApp:
            return "openApp"
        case .stopApp:
            return "stopApp"
        case .uninstallApp:
            return "uninstallApp"
        case .installApp:
            return "installApp"
        case nil:
            return "thirdApp"
        }
    }

    private func noteThirdAppResult(kind: ThirdAppRequestKind, success: Bool) {
        preconditionLock.lock()
        defer { preconditionLock.unlock() }
        switch kind {
        case .openApp:
            openAppSucceeded = success
        case .stopApp, .uninstallApp:
            if success {
                openAppSucceeded = false
                targetAppResumeMatchesPage = false
            }
        case .queryApp, .installApp:
            break
        }
    }

    var audioEventPublisher: AnyPublisher<RGCxrClientAudioEvent, Never> {
        audioEventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { [weak self] _, ready in
                ready && (self?.auth.hasPermission(.microphone) ?? false)
            }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    var customViewRunningEventPublisher: AnyPublisher<RGCxrClientCustomViewRunningEvent, Never> {
        customViewRunningEventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in ready }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    var appResumeChangeEventPublisher: AnyPublisher<RGCxrClientAppResumeChangeEvent, Never> {
        appResumeChangeEventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in ready }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    var notifyEventPublisher: AnyPublisher<RGCxrClientNotifyEvent, Never> {
        notifyEventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in
                ready && RGCxrClientLifecycle.snapshot?.mode == .customApp
            }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    var deviceInfoEventPublisher: AnyPublisher<RGCxrDeviceInfo, Never> {
        deviceInfoEventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in ready }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    var wearingStatusEventPublisher: AnyPublisher<Bool, Never> {
        wearingStatusEventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in ready }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    var aiWakeInterruptEventPublisher: AnyPublisher<Bool, Never> {
        aiWakeInterruptEventSubject
            .combineLatest(RGCxrClientLifecycle.initializedSubject)
            .filter { _, ready in ready }
            .map { event, _ in event }
            .eraseToAnyPublisher()
    }

    internal var sessionStatePublisher: AnyPublisher<RGCxrSessionStateEvent, Never> {
        sessionStateStore.statePublisher
    }

    internal var sessionDestroyedPublisher: AnyPublisher<Void, Never> {
        sessionStateStore.destroyedPublisher
    }

    internal var currentSessionState: RGCxrSessionState {
        sessionStateStore.state
    }

    private let audioService = RGCxrClientAudioStreamService()
    private let photoService = RGCxrClientPhotoStreamService()
    private let audioUploadService = RGCxrClientAudioUploadService()
    private let apkUploadService = RGCxrClientApkUploadService()
    private let customCmdStreamUploadService = RGCxrClientCustomCmdStreamUploadService()
    private let customViewPayloadUploadService = RGCxrClientCustomViewPayloadUploadService()
    private var cancellables = Set<AnyCancellable>()
    private var pendingPhotoCallback: ((Data) -> Void)?
    private var thirdAppRequestId: Int = 0
    private var pendingThirdAppCallbacks: [Int: (Bool) -> Void] = [:]
    private var pendingInstallAppPayloads: [Int: Data] = [:]
    private var changeAudioSceneRequestId: Int = 0
    private var pendingChangeAudioSceneCallbacks: [Int: (Bool) -> Void] = [:]
    private var customViewRequestId: Int = 0
    private var pendingCustomViewBoolCallbacks: [Int: (Bool) -> Void] = [:]
    private var pendingCustomViewOpenCallbacks: [Int: (Bool, Int?) -> Void] = [:]
    private var pendingCustomViewCallbackMembers: [Int: String] = [:]
    private var pendingCustomViewTimeoutWorkItems: [Int: DispatchWorkItem] = [:]
    private let customViewTimeoutInterval: TimeInterval = 5.0
    /// `sendCustomViewIcons` / `openCustomView` / `updateCustomView` 经本地 TCP 传大文本，整体等待时间放宽。
    private let customViewPayloadClientTimeoutInterval: TimeInterval = 30.0
    private var pendingCustomViewTextPayloads: [Int: Data] = [:]
    private var customCmdRequestId: Int = 0
    private var pendingCustomCmdCallbacks: [Int: (Bool, Data?, Int32?, String?) -> Void] = [:]
    private var pendingCustomCmdTimeoutWorkItems: [Int: DispatchWorkItem] = [:]
    private var pendingCustomCmdCallbackMembers: [Int: String] = [:]
    private let customCmdTimeoutInterval: TimeInterval = 5.0
    private let customCmdStreamTimeoutInterval: TimeInterval = 30.0
    private var deviceInfoRequestId: Int = 0
    private var pendingDeviceInfoCallbacks: [Int: (RGCxrDeviceInfo?) -> Void] = [:]
    private var wearingSwitchRequestId: Int = 0
    private var pendingWearingSwitchCallbacks: [Int: (Bool) -> Void] = [:]
    private var deviceControlRequestId: Int = 0
    private var pendingSetBrightnessCallbacks: [Int: (Bool) -> Void] = [:]
    private var pendingGetBrightnessCallbacks: [Int: (Int?) -> Void] = [:]
    private var pendingSetVolumeCallbacks: [Int: (Bool) -> Void] = [:]
    private var pendingGetVolumeCallbacks: [Int: (Int?) -> Void] = [:]
    private var interruptAiWakeRequestId: Int = 0
    private var pendingInterruptAiWakeCallbacks: [Int: (Bool) -> Void] = [:]
    private var pendingCustomCmdStreamPayloads: [Int: Data] = [:]

    init() {
        audioService.delegate = self
        photoService.delegate = self
        audioUploadService.delegate = self
        apkUploadService.delegate = self
        customCmdStreamUploadService.delegate = self
        customViewPayloadUploadService.delegate = self
        setupAuthObserver()
        setupBLEObserver()
    }

    private func setupAuthObserver() {
        auth.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                switch event {
                case .authenticationSucceeded(_, _, let deviceName):
                    if let deviceName = deviceName, !deviceName.isEmpty {
                        RGLog.info("[CxrClient] 鉴权成功，自动连接 BLE: \(deviceName)")
                        self?.ble.connect(name: deviceName)
                    } else {
                        RGLog.warn("[CxrClient] 鉴权成功但无设备名，跳过 BLE 连接")
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func send(data: String) {
        guard RGCxrClientLifecycle.isInitialized else {
            RGLog.error("[CxrClient] send 在未初始化时被调用，已忽略")
            return
        }
        guard let token = auth.getCurrentToken(), !token.isEmpty else {
            RGLog.error("[CxrClient] send blocked: missing auth token")
            return
        }
        RGLog.info(data)
        ble.send(data: data, dataExt: token)
    }

    func handleOpenURL(_ url: URL) -> Bool {
        logPublicCall("handleOpenURL", "scheme: \(url.scheme ?? "nil"), host: \(url.host ?? "nil")")
        if ensureClientInitialized() != nil { return false }
        let handled = auth.handleCallback(url: url)
        logPublicCallback("handleOpenURL", "handled: \(handled)")
        return handled
    }

    private func setupBLEObserver() {
        ble.notifyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.handleNotify(response)
            }
            .store(in: &cancellables)

        ble.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.sessionStateStore.handleBLEConnected(connected)
            }
            .store(in: &cancellables)
    }

    private func handleNotify(_ response: String) {
        guard RGCxrClientLifecycle.isInitialized else { return }
        guard let data = response.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            RGLog.warn("[CxrClient] 无法解析 notify 字符串: \(response)")
            return
        }
        handleGattMessage(message)
    }

    private func handleGattMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "localChannelStart":
            handleLocalChannelStart(message)
        case "localChannelStop":
            handleLocalChannelStop(message)
        case "customViewRunningStatus":
            handleCustomViewRunningStatus(message)
        case "appResumeChange":
            handleAppResumeChange(message)
        case "cxrNotify":
            handleCxrNotify(message)
        case "queryAppResult":
            handleThirdAppResult(message)
        case "openAppResult":
            handleThirdAppResult(message)
        case "stopAppResult":
            handleThirdAppResult(message)
        case "uninstallAppResult":
            handleThirdAppResult(message)
        case "installAppResult":
            handleThirdAppResult(message)
        case "changeAudioSceneIdResult":
            handleChangeAudioSceneIdResult(message)
        case "sendCustomCmdResult":
            handleSendCustomCmdResult(message)
        case "sendCustomCmdStreamResult":
            handleSendCustomCmdResult(message)
        case "deviceInfoResult":
            handleDeviceInfoResult(message)
        case "deviceInfoNotify":
            handleDeviceInfoNotify(message)
        case "wearingSwitchResult":
            handleWearingSwitchResult(message)
        case "wearingStatusNotify":
            handleWearingStatusNotify(message)
        case "setBrightnessResult":
            handleSetBrightnessResult(message)
        case "getBrightnessResult":
            handleGetBrightnessResult(message)
        case "setVolumeResult":
            handleSetVolumeResult(message)
        case "getVolumeResult":
            handleGetVolumeResult(message)
        case "interruptAiWakeResult":
            handleInterruptAiWakeResult(message)
        case "aiWakeInterruptNotify":
            handleAiWakeInterruptNotify(message)
        case "sessionLifecycleNotify":
            handleSessionLifecycleNotify(message)
        case "sendCustomViewIconsResult",
             "updateCustomViewResult",
             "closeCustomViewResult":
            handleCustomViewBoolResult(message)
        case "openCustomViewResult":
            handleCustomViewOpenResult(message)
        case "audioStart": // 兼容旧协议
            handleAudioStart(message)
        case "ping":
            audioService.onKeepAliveReceived()
            photoService.onKeepAliveReceived()
            audioUploadService.onKeepAliveReceived()
            apkUploadService.onKeepAliveReceived()
            customCmdStreamUploadService.onKeepAliveReceived()
            customViewPayloadUploadService.onKeepAliveReceived()
            sendPong()
        case "pong":
            audioService.onKeepAliveReceived()
            photoService.onKeepAliveReceived()
            audioUploadService.onKeepAliveReceived()
            apkUploadService.onKeepAliveReceived()
            customCmdStreamUploadService.onKeepAliveReceived()
            customViewPayloadUploadService.onKeepAliveReceived()
        default:
            break
        }
    }

    private func decodeCxrNotifyPayload(_ payload: Any?) -> Data? {
        guard let payload else { return nil }
        if let base64 = payload as? String, let data = Data(base64Encoded: base64) {
            return data
        }
        if let str = payload as? String {
            return str.data(using: .utf8)
        }
        if let data = payload as? Data {
            return data
        }
        if JSONSerialization.isValidJSONObject(payload),
           let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            return jsonData
        }
        return nil
    }

    private func handleCxrNotify(_ message: [String: Any]) {
        guard currentInitMode() == .customApp else {
            RGLog.warn("[CxrClient] cxrNotify 仅 customApp 模式支持，已忽略: \(message)")
            return
        }
        guard let data = message["data"] as? [String: Any],
              let cmd = data["cmd"] as? String,
              let subCmd = data["subCmd"] as? String,
              let reqId = data["reqId"] as? Int32,
              let status = data["status"] as? Int32 else {
            RGLog.error("[CxrClient] cxrNotify 参数不完整: \(message)")
            return
        }
        let trimmedCmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        preconditionLock.lock()
        let allowed = notifyListenCmds.contains(trimmedCmd)
        preconditionLock.unlock()
        guard allowed else {
            RGLog.debug("[CxrClient] cxrNotify cmd 未在白名单中，已忽略: \(trimmedCmd)")
            return
        }
        let payload = decodeCxrNotifyPayload(data["payload"])
        let payloadEx = decodeCxrNotifyPayload(data["payloadEx"])
        logPublicEvent("notifyEventPublisher", "cmd: \(trimmedCmd), subCmd: \(subCmd), reqId: \(reqId), status: \(status), payloadSize: \(payload?.count ?? 0), payloadExSize: \(payloadEx?.count ?? 0)")
        notifyEventSubject.send(
            RGCxrClientNotifyEvent(cmd: trimmedCmd,
                                   subCmd: subCmd,
                                   reqId: reqId,
                                   status: status,
                                   payload: payload,
                                   payloadEx: payloadEx)
        )
    }

    private func handleCustomViewRunningStatus(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let isRunning = data["customViewRunning"] as? Bool else {
            RGLog.error("[CxrClient] customViewRunningStatus 参数不完整: \(message)")
            return
        }
        preconditionLock.lock()
        isCustomViewRunning = isRunning
        preconditionLock.unlock()
        sessionStateStore.handleCustomViewRunning(isRunning)
        logPublicEvent("customViewRunningEventPublisher", "isRunning: \(isRunning)")
        customViewRunningEventSubject.send(RGCxrClientCustomViewRunningEvent(isRunning: isRunning))
    }

    private func handleAppResumeChange(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let packageName = data["packageName"] as? String,
              !packageName.isEmpty else {
            RGLog.error("[CxrClient] appResumeChange 参数不完整: \(message)")
            return
        }
        let trimmed = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = thirdPartyPagePackageName(), trimmed == target {
            preconditionLock.lock()
            targetAppResumeMatchesPage = true
            preconditionLock.unlock()
            sessionStateStore.handleTargetAppResumed(true)
        } else {
            preconditionLock.lock()
            targetAppResumeMatchesPage = false
            preconditionLock.unlock()
            sessionStateStore.handleTargetAppResumed(false)
        }
        logPublicEvent("appResumeChangeEventPublisher", "packageName: \(packageName)")
        appResumeChangeEventSubject.send(RGCxrClientAppResumeChangeEvent(packageName: packageName))
    }

    private func handleThirdAppResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] third app result 参数不完整: \(message)")
            return
        }
        let kind = pendingThirdAppRequestKinds.removeValue(forKey: requestId)
        let callback = pendingThirdAppCallbacks.removeValue(forKey: requestId)
        pendingInstallAppPayloads.removeValue(forKey: requestId)
        if let kind {
            noteThirdAppResult(kind: kind, success: success)
            if kind == .openApp, success {
                sessionStateStore.handleLifecycleNotify(state: .started, reason: .glassReady)
            } else if kind == .stopApp, success {
                sessionStateStore.handleLifecycleNotify(state: .unavailable, reason: .glassIdle)
            }
        }
        logPublicCallback(publicMemberName(for: kind), requestId: requestId, "success: \(success)")
        callback?(success)
    }

    private func nextThirdAppRequestId() -> Int {
        thirdAppRequestId += 1
        return thirdAppRequestId
    }

    private func nextChangeAudioSceneRequestId() -> Int {
        changeAudioSceneRequestId += 1
        return changeAudioSceneRequestId
    }

    private func nextDeviceControlRequestId() -> Int {
        deviceControlRequestId += 1
        return deviceControlRequestId
    }

    private func handleChangeAudioSceneIdResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] changeAudioSceneIdResult 参数不完整: \(message)")
            return
        }
        let callback = pendingChangeAudioSceneCallbacks.removeValue(forKey: requestId)
        logPublicCallback("changeAudioSceneId", requestId: requestId, "success: \(success)")
        callback?(success)
    }

    private func nextCustomViewRequestId() -> Int {
        customViewRequestId += 1
        return customViewRequestId
    }

    private func registerCustomViewBoolCallback(requestId: Int,
                                                callback: ((Bool) -> Void)?,
                                                member: String,
                                                responseTimeout: TimeInterval? = nil) {
        pendingCustomViewCallbackMembers[requestId] = member
        if let callback {
            pendingCustomViewBoolCallbacks[requestId] = callback
        }
        scheduleCustomViewTimeout(requestId: requestId, member: member, responseTimeout: responseTimeout)
    }

    private func registerCustomViewOpenCallback(requestId: Int,
                                                callback: ((Bool, Int?) -> Void)?,
                                                responseTimeout: TimeInterval? = nil) {
        pendingCustomViewCallbackMembers[requestId] = "openCustomView"
        if let callback {
            pendingCustomViewOpenCallbacks[requestId] = callback
        }
        scheduleCustomViewTimeout(requestId: requestId, member: "openCustomView", responseTimeout: responseTimeout)
    }

    private func scheduleCustomViewTimeout(requestId: Int, member: String, responseTimeout: TimeInterval? = nil) {
        let interval = responseTimeout ?? customViewTimeoutInterval
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingCustomViewTimeoutWorkItems.removeValue(forKey: requestId)
            self.pendingCustomViewTextPayloads.removeValue(forKey: requestId)
            self.pendingCustomViewCallbackMembers.removeValue(forKey: requestId)
            self.customViewPayloadUploadService.stop()
            if let callback = self.pendingCustomViewBoolCallbacks.removeValue(forKey: requestId) {
                RGLog.warn("[CxrClient] \(member) 眼镜响应超时, requestId: \(requestId)")
                self.logPublicCallback(member, requestId: requestId, "success: false, reason: timeout")
                callback(false)
            } else if let callback = self.pendingCustomViewOpenCallbacks.removeValue(forKey: requestId) {
                RGLog.warn("[CxrClient] \(member) 眼镜响应超时, requestId: \(requestId)")
                self.logPublicCallback(member, requestId: requestId, "success: false, errorCode: nil, reason: timeout")
                callback(false, nil)
            }
        }
        pendingCustomViewTimeoutWorkItems[requestId]?.cancel()
        pendingCustomViewTimeoutWorkItems[requestId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func cancelCustomViewTimeout(requestId: Int) {
        pendingCustomViewTimeoutWorkItems.removeValue(forKey: requestId)?.cancel()
    }

    private func nextCustomCmdRequestId() -> Int {
        customCmdRequestId += 1
        return customCmdRequestId
    }

    private func scheduleCustomCmdTimeout(requestId: Int, cmd: String, member: String, timeout: TimeInterval) {
        pendingCustomCmdCallbackMembers[requestId] = member
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCustomCmdTimeoutWorkItems.removeValue(forKey: requestId)
            self.pendingCustomCmdStreamPayloads.removeValue(forKey: requestId)
            let member = self.pendingCustomCmdCallbackMembers.removeValue(forKey: requestId) ?? "sendCustomCmd"
            if let callback = self.pendingCustomCmdCallbacks.removeValue(forKey: requestId) {
                RGLog.warn("[CxrClient] sendCustomCmd 眼镜响应超时, cmd: \(cmd), requestId: \(requestId)")
                self.logPublicCallback(member, requestId: requestId, "success: false, payloadSize: 0, errorCode: nil, errorMsg: nil, reason: timeout")
                callback(false, nil, nil, nil)
            }
        }
        pendingCustomCmdTimeoutWorkItems[requestId]?.cancel()
        pendingCustomCmdTimeoutWorkItems[requestId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelCustomCmdTimeout(requestId: Int) {
        pendingCustomCmdTimeoutWorkItems.removeValue(forKey: requestId)?.cancel()
    }

    private func handleSendCustomCmdResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] sendCustomCmdResult 参数不完整: \(message)")
            return
        }
        cancelCustomCmdTimeout(requestId: requestId)
        let payloadBase64 = data["payload"] as? String
        let payloadData: Data? = {
            guard let payloadBase64, !payloadBase64.isEmpty else { return nil }
            guard let decoded = Data(base64Encoded: payloadBase64) else {
                RGLog.warn("[CxrClient] sendCustomCmdResult payload base64 解码失败, requestId: \(requestId)")
                return nil
            }
            return decoded
        }()
        let errorCode = data["errorCode"] as? Int32
        let errorMsg = data["errorMsg"] as? String
        pendingCustomCmdStreamPayloads.removeValue(forKey: requestId)
        let callback = pendingCustomCmdCallbacks.removeValue(forKey: requestId)
        let member = pendingCustomCmdCallbackMembers.removeValue(forKey: requestId) ?? "sendCustomCmd"
        logPublicCallback(member, requestId: requestId, "success: \(success), payloadSize: \(payloadData?.count ?? 0), errorCode: \(String(describing: errorCode)), errorMsg: \(String(describing: errorMsg))")
        callback?(success, payloadData, errorCode, errorMsg)
    }

    private func handleDeviceInfoResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int else {
            RGLog.error("[CxrClient] deviceInfoResult 参数不完整: \(message)")
            return
        }
        let deviceInfo = (data["deviceInfo"] as? [String: Any]).map { RGCxrDeviceInfo.from(dictionary: $0) }
        if let deviceInfo {
            logPublicEvent("deviceInfoEventPublisher", "source: getDeviceInfoResult, requestId: \(requestId)")
            deviceInfoEventSubject.send(deviceInfo)
        }
        let callback = pendingDeviceInfoCallbacks.removeValue(forKey: requestId)
        logPublicCallback("getDeviceInfo", requestId: requestId, "hasDeviceInfo: \(deviceInfo != nil)")
        callback?(deviceInfo)
    }

    private func handleDeviceInfoNotify(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let deviceInfoData = data["deviceInfo"] as? [String: Any] else {
            RGLog.error("[CxrClient] deviceInfoNotify 参数不完整: \(message)")
            return
        }
        logPublicEvent("deviceInfoEventPublisher", "source: notify")
        deviceInfoEventSubject.send(RGCxrDeviceInfo.from(dictionary: deviceInfoData))
    }

    private func handleWearingSwitchResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let switchOn = data["switchOn"] as? Bool else {
            RGLog.error("[CxrClient] wearingSwitchResult 参数不完整: \(message)")
            return
        }
        let callback = pendingWearingSwitchCallbacks.removeValue(forKey: requestId)
        logPublicCallback("getWearingSwitch", requestId: requestId, "switchOn: \(switchOn)")
        callback?(switchOn)
    }

    private func handleWearingStatusNotify(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let wearing = data["wearing"] as? Bool else {
            RGLog.error("[CxrClient] wearingStatusNotify 参数不完整: \(message)")
            return
        }
        logPublicEvent("wearingStatusEventPublisher", "wearing: \(wearing)")
        wearingStatusEventSubject.send(wearing)
    }

    private func intValue(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func deviceControlLevel(from data: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let level = intValue(from: data[key]) {
                return level
            }
        }
        return nil
    }

    private func handleSetBrightnessResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] setBrightnessResult 参数不完整: \(message)")
            return
        }
        let callback = pendingSetBrightnessCallbacks.removeValue(forKey: requestId)
        logPublicCallback("setBrightness", requestId: requestId, "success: \(success)")
        callback?(success)
    }

    private func handleGetBrightnessResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int else {
            RGLog.error("[CxrClient] getBrightnessResult 参数不完整: \(message)")
            return
        }
        let level = deviceControlLevel(from: data, keys: ["level", "brightness"])
        let callback = pendingGetBrightnessCallbacks.removeValue(forKey: requestId)
        logPublicCallback("getBrightness", requestId: requestId, "level: \(String(describing: level))")
        callback?(level)
    }

    private func handleSetVolumeResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] setVolumeResult 参数不完整: \(message)")
            return
        }
        let callback = pendingSetVolumeCallbacks.removeValue(forKey: requestId)
        logPublicCallback("setVolume", requestId: requestId, "success: \(success)")
        callback?(success)
    }

    private func handleGetVolumeResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int else {
            RGLog.error("[CxrClient] getVolumeResult 参数不完整: \(message)")
            return
        }
        let level = deviceControlLevel(from: data, keys: ["level", "volume", "sound"])
        let callback = pendingGetVolumeCallbacks.removeValue(forKey: requestId)
        logPublicCallback("getVolume", requestId: requestId, "level: \(String(describing: level))")
        callback?(level)
    }

    private func handleInterruptAiWakeResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] interruptAiWakeResult 参数不完整: \(message)")
            return
        }
        let callback = pendingInterruptAiWakeCallbacks.removeValue(forKey: requestId)
        logPublicCallback("interruptAiWake", requestId: requestId, "success: \(success)")
        callback?(success)
    }

    private func handleAiWakeInterruptNotify(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let interruptWake = data["interruptWake"] as? Bool else {
            RGLog.error("[CxrClient] aiWakeInterruptNotify 参数不完整: \(message)")
            return
        }
        logPublicEvent("aiWakeInterruptEventPublisher", "interruptWake: \(interruptWake)")
        aiWakeInterruptEventSubject.send(interruptWake)
    }

    private func handleSessionLifecycleNotify(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let stateValue = data["state"] as? String,
              let state = RGCxrSessionState(rawValue: stateValue) else {
            RGLog.error("[CxrClient] sessionLifecycleNotify 参数不完整: \(message)")
            return
        }
        let reason: RGCxrSessionStateReason?
        if let reasonValue = data["reason"] as? String {
            reason = RGCxrSessionStateReason(rawValue: reasonValue) ?? .other
        } else {
            reason = nil
        }
        if state == .paused {
            stopActiveLocalStreamsForPause()
        }
        sessionStateStore.handleLifecycleNotify(state: state, reason: reason)
    }

    private func stopActiveLocalStreamsForPause() {
        audioService.stop()
        photoService.stop()
        audioUploadService.stop()
        pendingPhotoCallback = nil
        sessionStateStore.markAudioStreamActive(false)
    }

    private func handleCustomViewBoolResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] customView result 参数不完整: \(message)")
            return
        }
        cancelCustomViewTimeout(requestId: requestId)
        let callback = pendingCustomViewBoolCallbacks.removeValue(forKey: requestId)
        let member = pendingCustomViewCallbackMembers.removeValue(forKey: requestId) ?? "customView"
        logPublicCallback(member, requestId: requestId, "success: \(success)")
        callback?(success)
    }

    private func handleCustomViewOpenResult(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let success = data["success"] as? Bool else {
            RGLog.error("[CxrClient] openCustomViewResult 参数不完整: \(message)")
            return
        }
        cancelCustomViewTimeout(requestId: requestId)
        let errorCode = data["errorCode"] as? Int
        let callback = pendingCustomViewOpenCallbacks.removeValue(forKey: requestId)
        pendingCustomViewCallbackMembers.removeValue(forKey: requestId)
        logPublicCallback("openCustomView", requestId: requestId, "success: \(success), errorCode: \(String(describing: errorCode))")
        callback?(success, errorCode)
    }

    private func handleLocalChannelStop(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let channelId = data["channelId"] as? String else {
            RGLog.error("[CxrClient] localChannelStop 参数不完整: \(message)")
            return
        }

        switch channelId {
        case "audio_down":
            audioService.stop()
        case "photo":
            photoService.stop()
            pendingPhotoCallback = nil
        case "audio_up":
            audioUploadService.stop()
        case "apk_upload":
            apkUploadService.stop()
        case "custom_cmd_upload":
            customCmdStreamUploadService.stop()
        case "custom_view_upload":
            customViewPayloadUploadService.stop()
        default:
            RGLog.warn("[CxrClient] 收到未支持的通道关闭: \(channelId)")
        }
    }

    /// 处理通用本地通道启动消息
    /// 当前只支持 audio_down 通道，其他通道后续按需扩展
    private func handleLocalChannelStart(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let channelId = data["channelId"] as? String,
              let port = data["port"] as? UInt16 else {
            RGLog.error("[CxrClient] localChannelStart 参数不完整: \(message)")
            return
        }

        let mode = (data["mode"] as? String) ?? "stream"
        let metadata = data["metadata"] as? [String: Any]

        switch channelId {
        case "audio_down":
            if mode != "stream" {
                RGLog.warn("[CxrClient] audio_down 通道当前仅支持 stream 模式，实际为: \(mode)")
            }
            let codec = (metadata?["codec"] as? Int32) ?? 0
            let type = (metadata?["type"] as? String) ?? "default"
            let channels = (metadata?["channels"] as? UInt32) ?? 1
            let info = RGCxrClientAudioStreamInfo(port: port, codec: codec, type: type, channels: channels)
            audioService.start(info: info)

        case "photo":
            if mode != "chunk" && mode != "stream" {
                RGLog.warn("[CxrClient] photo 通道模式异常: \(mode)，继续按单包协议接收")
            }
            photoService.start(port: port)

        case "audio_up":
            if mode != "stream" {
                RGLog.warn("[CxrClient] audio_up 通道当前仅支持 stream 模式，实际为: \(mode)")
            }
            audioUploadService.start(port: port)

        case "apk_upload":
            guard let requestId = metadata?["requestId"] as? Int else {
                RGLog.error("[CxrClient] apk_upload 缺少 requestId: \(String(describing: metadata))")
                return
            }
            guard let payload = pendingInstallAppPayloads[requestId] else {
                RGLog.error("[CxrClient] apk_upload 未找到待上传数据, requestId: \(requestId)")
                return
            }
            if mode != "chunk" && mode != "stream" {
                RGLog.warn("[CxrClient] apk_upload 通道模式异常: \(mode)，继续按单包协议发送")
            }
            apkUploadService.start(requestId: requestId, port: port, payload: payload)

        case "custom_cmd_upload":
            guard let requestId = metadata?["requestId"] as? Int else {
                RGLog.error("[CxrClient] custom_cmd_upload 缺少 requestId: \(String(describing: metadata))")
                return
            }
            guard let stream = pendingCustomCmdStreamPayloads[requestId] else {
                RGLog.error("[CxrClient] custom_cmd_upload 未找到待上传数据, requestId: \(requestId)")
                return
            }
            if mode != "chunk" && mode != "stream" {
                RGLog.warn("[CxrClient] custom_cmd_upload 通道模式异常: \(mode)，继续按单包协议发送")
            }
            customCmdStreamUploadService.start(requestId: requestId, port: port, stream: stream)

        case "custom_view_upload":
            guard let requestId = metadata?["requestId"] as? Int else {
                RGLog.error("[CxrClient] custom_view_upload 缺少 requestId: \(String(describing: metadata))")
                return
            }
            guard let payload = pendingCustomViewTextPayloads[requestId] else {
                RGLog.error("[CxrClient] custom_view_upload 未找到待上传数据, requestId: \(requestId)")
                return
            }
            if mode != "chunk" && mode != "stream" {
                RGLog.warn("[CxrClient] custom_view_upload 通道模式异常: \(mode)，继续按单包协议发送")
            }
            customViewPayloadUploadService.start(requestId: requestId, port: port, payload: payload)

        default:
            RGLog.warn("[CxrClient] 收到未支持的本地通道: \(channelId)")
        }
    }

    private func handleAudioStart(_ message: [String: Any]) {
        guard let data = message["data"] as? [String: Any],
              let port = data["port"] as? UInt16,
              let codec = data["codec"] as? Int32,
              let type = data["type"] as? String,
              let channels = data["channels"] as? UInt32 else {
            RGLog.error("[CxrClient] audioStart 参数不完整: \(message)")
            return
        }

        let info = RGCxrClientAudioStreamInfo(port: port, codec: codec, type: type, channels: channels)
        audioService.start(info: info)
    }

    private func sendPing() {
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "ping"
        ]
        sendGattMessage(payload)
    }

    private func sendPong() {
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "pong"
        ]
        sendGattMessage(payload)
    }

    private func sendGattMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: jsonData, encoding: .utf8) else {
            RGLog.error("[CxrClient] 构建 GATT 消息失败")
            return
        }
        send(data: json)
    }

    @discardableResult
    internal func sendCustomViewIcons(_ icons: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("sendCustomViewIcons", "iconsSize: \(icons.utf8.count), hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customView) { return err }
        let requestId = nextCustomViewRequestId()
        registerCustomViewBoolCallback(
            requestId: requestId,
            callback: callback,
            member: "sendCustomViewIcons",
            responseTimeout: customViewPayloadClientTimeoutInterval
        )
        let utf8 = Data(icons.utf8)
        pendingCustomViewTextPayloads[requestId] = utf8
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "sendCustomViewIcons",
            "data": [
                "requestId": requestId
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("sendCustomViewIcons", requestId: requestId, "iconsSize: \(utf8.count)")
        return nil
    }

    @discardableResult
    internal func sendCustomCmd(cmd: String,
                                payload: Data?,
                                callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError? {
        logPublicCall("sendCustomCmd", "cmd: \(cmd), payloadSize: \(payload?.count ?? 0), hasCallback: \(callback != nil)")
        if let err = precheck(requireAppResumed: true) { return err }
        let cmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else {
            RGLog.error("[CxrClient] sendCustomCmd: cmd 不能为空")
            logPublicCallback("sendCustomCmd", "success: false, payloadSize: 0, errorCode: nil, errorMsg: nil, reason: empty cmd")
            callback?(false, nil, nil, nil)
            return nil
        }
        let requestId = nextCustomCmdRequestId()
        if let callback {
            pendingCustomCmdCallbacks[requestId] = callback
        }
        scheduleCustomCmdTimeout(requestId: requestId, cmd: cmd, member: "sendCustomCmd", timeout: customCmdTimeoutInterval)
        var data: [String: Any] = [
            "requestId": requestId,
            "cmd": cmd
        ]
        if let payload {
            data["payload"] = payload.base64EncodedString()
        }
        let msg: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "sendCustomCmd",
            "data": data
        ]
        sendGattMessage(msg)
        logPublicSent("sendCustomCmd", requestId: requestId, "cmd: \(cmd), payloadSize: \(payload?.count ?? 0)")
        return nil
    }

    @discardableResult
    func sendCustomCmd(cmd: String, payload: Data?) -> RGCxrClientError? {
        logPublicCall("sendCustomCmdWithoutCallback", "cmd: \(cmd), payloadSize: \(payload?.count ?? 0)")
        return sendCustomCmd(cmd: cmd, payload: payload, callback: nil)
    }

    @discardableResult
    internal func sendCustomCmdStream(cmd: String,
                                      payload: Data?,
                                      stream: Data,
                                      callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError? {
        logPublicCall("sendCustomCmdStream", "cmd: \(cmd), payloadSize: \(payload?.count ?? 0), streamSize: \(stream.count), hasCallback: \(callback != nil)")
        if let err = precheck(requireAppResumed: true) { return err }
        let cmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else {
            RGLog.error("[CxrClient] sendCustomCmdStream: cmd 不能为空")
            logPublicCallback("sendCustomCmdStream", "success: false, payloadSize: 0, errorCode: nil, errorMsg: nil, reason: empty cmd")
            callback?(false, nil, nil, nil)
            return nil
        }
        guard !stream.isEmpty else {
            RGLog.error("[CxrClient] sendCustomCmdStream: stream 不能为空")
            logPublicCallback("sendCustomCmdStream", "success: false, payloadSize: 0, errorCode: nil, errorMsg: nil, reason: empty stream")
            callback?(false, nil, nil, nil)
            return nil
        }
        let requestId = nextCustomCmdRequestId()
        pendingCustomCmdStreamPayloads[requestId] = stream
        if let callback {
            pendingCustomCmdCallbacks[requestId] = callback
        }
        scheduleCustomCmdTimeout(requestId: requestId, cmd: cmd, member: "sendCustomCmdStream", timeout: customCmdStreamTimeoutInterval)
        var data: [String: Any] = [
            "requestId": requestId,
            "cmd": cmd
        ]
        if let payload {
            data["payload"] = payload.base64EncodedString()
        }
        let msg: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "sendCustomCmdStream",
            "data": data
        ]
        sendGattMessage(msg)
        logPublicSent("sendCustomCmdStream", requestId: requestId, "cmd: \(cmd), payloadSize: \(payload?.count ?? 0), streamSize: \(stream.count)")
        return nil
    }

    @discardableResult
    internal func getDeviceInfo(callback: ((RGCxrDeviceInfo?) -> Void)?) -> RGCxrClientError? {
        logPublicCall("getDeviceInfo", "hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customApp) { return err }
        deviceInfoRequestId += 1
        let requestId = deviceInfoRequestId
        if let callback {
            pendingDeviceInfoCallbacks[requestId] = callback
        }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "getDeviceInfo",
            "data": [
                "requestId": requestId
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("getDeviceInfo", requestId: requestId)
        return nil
    }

    @discardableResult
    internal func getWearingSwitch(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("getWearingSwitch", "hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customApp) { return err }
        wearingSwitchRequestId += 1
        let requestId = wearingSwitchRequestId
        if let callback {
            pendingWearingSwitchCallbacks[requestId] = callback
        }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "getWearingSwitch",
            "data": [
                "requestId": requestId
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("getWearingSwitch", requestId: requestId)
        return nil
    }

    @discardableResult
    internal func setBrightness(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("setBrightness", "level: \(level), hasCallback: \(callback != nil)")
        if let err = precheck(requireMediaReady: true) { return err }
        guard (0...15).contains(level) else {
            RGLog.error("[CxrClient] setBrightness: level 超出范围 0...15: \(level)")
            logPublicCallback("setBrightness", "success: false, reason: invalid level")
            callback?(false)
            return nil
        }
        let requestId = nextDeviceControlRequestId()
        if let callback {
            pendingSetBrightnessCallbacks[requestId] = callback
        }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "setBrightness",
            "data": [
                "requestId": requestId,
                "level": level
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("setBrightness", requestId: requestId, "level: \(level)")
        return nil
    }

    @discardableResult
    internal func getBrightness(callback: ((Int?) -> Void)?) -> RGCxrClientError? {
        logPublicCall("getBrightness", "hasCallback: \(callback != nil)")
        if let err = precheck() { return err }
        let requestId = nextDeviceControlRequestId()
        if let callback {
            pendingGetBrightnessCallbacks[requestId] = callback
        }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "getBrightness",
            "data": [
                "requestId": requestId
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("getBrightness", requestId: requestId)
        return nil
    }

    @discardableResult
    internal func setVolume(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("setVolume", "level: \(level), hasCallback: \(callback != nil)")
        if let err = precheck(requireMediaReady: true) { return err }
        guard (0...15).contains(level) else {
            RGLog.error("[CxrClient] setVolume: level 超出范围 0...15: \(level)")
            logPublicCallback("setVolume", "success: false, reason: invalid level")
            callback?(false)
            return nil
        }
        let requestId = nextDeviceControlRequestId()
        if let callback {
            pendingSetVolumeCallbacks[requestId] = callback
        }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "setVolume",
            "data": [
                "requestId": requestId,
                "level": level
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("setVolume", requestId: requestId, "level: \(level)")
        return nil
    }

    @discardableResult
    internal func getVolume(callback: ((Int?) -> Void)?) -> RGCxrClientError? {
        logPublicCall("getVolume", "hasCallback: \(callback != nil)")
        if let err = precheck() { return err }
        let requestId = nextDeviceControlRequestId()
        if let callback {
            pendingGetVolumeCallbacks[requestId] = callback
        }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "getVolume",
            "data": [
                "requestId": requestId
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("getVolume", requestId: requestId)
        return nil
    }

    @discardableResult
    internal func interruptAiWake(_ interruptWake: Bool, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("interruptAiWake", "interruptWake: \(interruptWake), hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customApp) { return err }
        interruptAiWakeRequestId += 1
        let requestId = interruptAiWakeRequestId
        if let callback {
            pendingInterruptAiWakeCallbacks[requestId] = callback
        }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "interruptAiWake",
            "data": [
                "requestId": requestId,
                "interruptWake": interruptWake
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("interruptAiWake", requestId: requestId, "interruptWake: \(interruptWake)")
        return nil
    }

    @discardableResult
    internal func setNotifyEventListenCmds(_ cmds: [String]) -> RGCxrClientError? {
        logPublicCall("setNotifyEventListenCmds", "count: \(cmds.count)")
        if let err = precheck(requiredMode: .customApp) { return err }
        let normalized = Set(
            cmds
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        preconditionLock.lock()
        notifyListenCmds = normalized
        preconditionLock.unlock()
        RGLog.info("[CxrClient] notify cmd 白名单已更新, count: \(normalized.count)")
        logPublicSent("setNotifyEventListenCmds", "normalizedCount: \(normalized.count)")
        return nil
    }

    @discardableResult
    internal func openCustomView(_ view: String, callback: ((Bool, Int?) -> Void)?) -> RGCxrClientError? {
        logPublicCall("openCustomView", "viewSize: \(view.utf8.count), hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customView) { return err }
        let requestId = nextCustomViewRequestId()
        registerCustomViewOpenCallback(
            requestId: requestId,
            callback: callback,
            responseTimeout: customViewPayloadClientTimeoutInterval
        )
        pendingCustomViewTextPayloads[requestId] = Data(view.utf8)
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "openCustomView",
            "data": [
                "requestId": requestId
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("openCustomView", requestId: requestId, "viewSize: \(view.utf8.count)")
        return nil
    }

    @discardableResult
    internal func updateCustomView(_ view: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("updateCustomView", "viewSize: \(view.utf8.count), hasCallback: \(callback != nil)")
        if let err = precheck(requireCustomViewRunning: true) { return err }
        let requestId = nextCustomViewRequestId()
        registerCustomViewBoolCallback(
            requestId: requestId,
            callback: callback,
            member: "updateCustomView",
            responseTimeout: customViewPayloadClientTimeoutInterval
        )
        pendingCustomViewTextPayloads[requestId] = Data(view.utf8)
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "updateCustomView",
            "data": [
                "requestId": requestId
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("updateCustomView", requestId: requestId, "viewSize: \(view.utf8.count)")
        return nil
    }

    @discardableResult
    internal func closeCustomView(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("closeCustomView", "hasCallback: \(callback != nil)")
        if let err = precheck(requireCustomViewRunning: true) { return err }
        let requestId = nextCustomViewRequestId()
        registerCustomViewBoolCallback(requestId: requestId, callback: callback, member: "closeCustomView")
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "closeCustomView",
            "data": [
                "requestId": requestId,
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("closeCustomView", requestId: requestId)
        return nil
    }

    @discardableResult
    internal func startRecord(_ type: String, codec: RGCxrAudioCodec, mode: RGCxrAudioMode) -> RGCxrClientError? {
        logPublicCall("startRecord", "type: \(type), codec: \(codec.rawValue), mode: \(mode.rawValue)")
        if let err = precheck(requiredPermission: .microphone, requireMediaReady: true) { return err }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "startRecord",
            "data": [
                "type": type,
                "codec": codec.rawValue,
                "mode": mode.rawValue
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("startRecord", "type: \(type), codec: \(codec.rawValue), mode: \(mode.rawValue)")
        return nil
    }

    @discardableResult
    internal func stopRecord(_ type: String) -> RGCxrClientError? {
        logPublicCall("stopRecord", "type: \(type)")
        if let err = precheck(requiredPermission: .microphone, requireMediaReady: true) { return err }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "stopRecord",
            "data": [
                "type": type
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("stopRecord", "type: \(type)")
        return nil
    }

    @discardableResult
    internal func startPlayAudio(codec: RGCxrAudioCodec) -> RGCxrClientError? {
        logPublicCall("startPlayAudio", "codec: \(codec.rawValue)")
        if let err = precheck(requireMediaReady: true) { return err }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "startPlayAudio",
            "data": [
                "codec": codec.rawValue
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("startPlayAudio", "codec: \(codec.rawValue)")
        return nil
    }

    @discardableResult
    internal func stopPlayAudio() -> RGCxrClientError? {
        logPublicCall("stopPlayAudio")
        if let err = precheck(requireMediaReady: true) { return err }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "stopPlayAudio"
        ]
        sendGattMessage(payload)
        logPublicSent("stopPlayAudio")
        return nil
    }

    @discardableResult
    internal func feedAudio(_ data: Data) -> RGCxrClientError? {
        logPublicCall("feedAudio", "dataSize: \(data.count)")
        if let err = precheck(requireMediaReady: true) { return err }
        audioUploadService.sendAudio(data)
        logPublicSent("feedAudio", "dataSize: \(data.count)")
        return nil
    }

    @discardableResult
    internal func takePhoto() -> RGCxrClientError? {
        logPublicCall("takePhoto")
        if let err = precheck(requiredPermission: .camera, requireMediaReady: true) { return err }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "takePhoto",
        ]
        sendGattMessage(payload)
        logPublicSent("takePhoto")
        return nil
    }

    @discardableResult
    internal func takePhotoWithData(width: Int, height: Int, quality: Int, callback: ((Data) -> Void)?) -> RGCxrClientError? {
        logPublicCall("takePhotoWithData", "width: \(width), height: \(height), quality: \(quality), hasCallback: \(callback != nil)")
        if let err = precheck(requiredPermission: .camera, requireMediaReady: true) { return err }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "takePhotoWithData",
            "data": [
                "width": width,
                "height": height,
                "quality": quality
            ]
        ]
        pendingPhotoCallback = callback
        sendGattMessage(payload)
        logPublicSent("takePhotoWithData", "width: \(width), height: \(height), quality: \(quality)")
        return nil
    }

    @discardableResult
    internal func queryApp(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("queryApp", "hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customApp) { return err }
        guard let packageName = thirdPartyPagePackageName() else {
            RGLog.error("[CxrClient] queryApp 需要先在 CxrClient.initialize 中设置 RGCxrClientInitializationOptions.pageName（眼镜端包名）")
            logPublicCallback("queryApp", "success: false, reason: missing pageName")
            callback?(false)
            return nil
        }
        let requestId = nextThirdAppRequestId()
        pendingThirdAppRequestKinds[requestId] = .queryApp
        if let callback { pendingThirdAppCallbacks[requestId] = callback }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "queryApp",
            "data": [
                "requestId": requestId,
                "packageName": packageName
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("queryApp", requestId: requestId, "packageName: \(packageName)")
        return nil
    }

    @discardableResult
    internal func openApp(activityName: String, url: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("openApp", "activityName: \(activityName), hasURL: \(!url.isEmpty), urlSize: \(url.utf8.count), hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customApp) { return err }
        guard let packageName = thirdPartyPagePackageName() else {
            RGLog.error("[CxrClient] openApp 需要先在 CxrClient.initialize 中设置 RGCxrClientInitializationOptions.pageName（眼镜端包名）")
            logPublicCallback("openApp", "success: false, reason: missing pageName")
            callback?(false)
            return nil
        }
        let requestId = nextThirdAppRequestId()
        pendingThirdAppRequestKinds[requestId] = .openApp
        if let callback { pendingThirdAppCallbacks[requestId] = callback }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "openApp",
            "data": [
                "requestId": requestId,
                "packageName": packageName,
                "activityName": activityName,
                "url": url
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("openApp", requestId: requestId, "packageName: \(packageName), activityName: \(activityName), hasURL: \(!url.isEmpty)")
        return nil
    }

    @discardableResult
    internal func stopApp(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("stopApp", "hasCallback: \(callback != nil)")
        if let err = precheck(requireAppResumed: true) { return err }
        guard let packageName = thirdPartyPagePackageName() else {
            RGLog.error("[CxrClient] stopApp 需要先在 CxrClient.initialize 中设置 RGCxrClientInitializationOptions.pageName（眼镜端包名）")
            logPublicCallback("stopApp", "success: false, reason: missing pageName")
            callback?(false)
            return nil
        }
        let requestId = nextThirdAppRequestId()
        pendingThirdAppRequestKinds[requestId] = .stopApp
        if let callback { pendingThirdAppCallbacks[requestId] = callback }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "stopApp",
            "data": [
                "requestId": requestId,
                "packageName": packageName
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("stopApp", requestId: requestId, "packageName: \(packageName)")
        return nil
    }

    @discardableResult
    internal func uninstallApp(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("uninstallApp", "hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customApp) { return err }
        guard let packageName = thirdPartyPagePackageName() else {
            RGLog.error("[CxrClient] uninstallApp 需要先在 CxrClient.initialize 中设置 RGCxrClientInitializationOptions.pageName（眼镜端包名）")
            logPublicCallback("uninstallApp", "success: false, reason: missing pageName")
            callback?(false)
            return nil
        }
        let requestId = nextThirdAppRequestId()
        pendingThirdAppRequestKinds[requestId] = .uninstallApp
        if let callback { pendingThirdAppCallbacks[requestId] = callback }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "uninstallApp",
            "data": [
                "requestId": requestId,
                "packageName": packageName
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("uninstallApp", requestId: requestId, "packageName: \(packageName)")
        return nil
    }

    @discardableResult
    internal func installApp(_ path: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("installApp", "path: \(path), hasCallback: \(callback != nil)")
        if let err = precheck(requiredMode: .customApp) { return err }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            RGLog.error("[CxrClient] installApp 文件不存在: \(path)")
            logPublicCallback("installApp", "success: false, reason: file missing")
            callback?(false)
            return nil
        }
        guard let payloadData = try? Data(contentsOf: url) else {
            RGLog.error("[CxrClient] installApp 读取文件失败: \(path)")
            logPublicCallback("installApp", "success: false, reason: read failed")
            callback?(false)
            return nil
        }

        let requestId = nextThirdAppRequestId()
        pendingThirdAppRequestKinds[requestId] = .installApp
        if let callback { pendingThirdAppCallbacks[requestId] = callback }
        pendingInstallAppPayloads[requestId] = payloadData

        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "installApp",
            "data": [
                "requestId": requestId,
                "fileName": url.lastPathComponent
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("installApp", requestId: requestId, "fileName: \(url.lastPathComponent), fileSize: \(payloadData.count)")
        return nil
    }

    @discardableResult
    internal func changeAudioSceneId(_ audioSceneId: RGCxrAudioSceneId, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        logPublicCall("changeAudioSceneId", "audioSceneId: \(audioSceneId.rawValue), hasCallback: \(callback != nil)")
        if let err = precheck(requireMediaReady: true) { return err }
        let requestId = nextChangeAudioSceneRequestId()
        if let callback { pendingChangeAudioSceneCallbacks[requestId] = callback }
        let payload: [String: Any] = [
            "bundleId": gattHostBundleId,
            "type": "changeAudioSceneId",
            "data": [
                "requestId": requestId,
                "audioSceneId": audioSceneId.rawValue
            ]
        ]
        sendGattMessage(payload)
        logPublicSent("changeAudioSceneId", requestId: requestId, "audioSceneId: \(audioSceneId.rawValue)")
        return nil
    }

    internal func isRokidAppInstalled() -> Bool {
        // iOS 不支持按 bundleId（com.rokid.rokidglasses）直接查询安装状态，
        // 通过 Rokid App 注册的 URL Scheme `rokidai` 判断；
        // 调用方需在 Info.plist 的 `LSApplicationQueriesSchemes` 中声明 `rokidai`。
        guard let url = URL(string: "rokidai://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

extension RGCxrClientImpl: RGCxrClientAudioStreamServiceDelegate {

    func audioStreamServiceDidStart(info: RGCxrClientAudioStreamInfo) {
        RGLog.info("[CxrClient] audio stream started, port: \(info.port), codec: \(info.codec), type: \(info.type), channels: \(info.channels)")
        logPublicEvent("audioEventPublisher", "started, codec: \(info.codec), type: \(info.type), channels: \(info.channels)")
        audioEventSubject.send(.started(RGCxrClientAudioStartEvent(codec: info.codec, type: info.type, channels: info.channels)))
    }

    func audioStreamServiceDidConnect(port: UInt16) {
        RGLog.info("[CxrClient] audio tcp connected, port: \(port)")
    }

    func audioStreamServiceDidReceive(packet: RGCxrClientAudioPacket) {
        RGLog.debug("[CxrClient] received audio packet size: \(packet.data.count), ts: \(packet.timestamp)")
        logPublicEvent("audioEventPublisher", "stream, dataSize: \(packet.data.count), timestamp: \(packet.timestamp)")
        audioEventSubject.send(.stream(RGCxrClientAudioDataEvent(data: packet.data, timestamp: packet.timestamp)))
    }

    func audioStreamServiceDidStop() {
        RGLog.info("[CxrClient] audio stream stopped")
    }

    func audioStreamServiceDidFail(error: Error) {
        if (error as NSError).code == -1001 {
            RGLog.warn("[CxrClient] heartbeat timeout, stop audio stream")
        }
        RGLog.error("[CxrClient] audio stream error: \(error.localizedDescription)")
    }

    func audioStreamServiceSendPing() {
        sendPing()
    }
}

extension RGCxrClientImpl: RGCxrClientPhotoStreamServiceDelegate {

    func photoStreamServiceDidConnect(port: UInt16) {
        RGLog.info("[CxrClient] photo tcp connected, port: \(port)")
    }

    func photoStreamServiceDidReceive(photoData: Data) {
        RGLog.info("[CxrClient] received photo data size: \(photoData.count)")
        let callback = pendingPhotoCallback
        pendingPhotoCallback = nil
        logPublicCallback("takePhotoWithData", "dataSize: \(photoData.count)")
        callback?(photoData)
    }

    func photoStreamServiceDidStop() {
        RGLog.info("[CxrClient] photo stream stopped")
    }

    func photoStreamServiceDidFail(error: Error) {
        if (error as NSError).code == -1001 {
            RGLog.warn("[CxrClient] heartbeat timeout, stop photo stream")
        }
        RGLog.error("[CxrClient] photo stream error: \(error.localizedDescription)")
        pendingPhotoCallback = nil
    }

    func photoStreamServiceSendPing() {
        sendPing()
    }
}

extension RGCxrClientImpl: RGCxrClientAudioUploadServiceDelegate {

    func audioUploadServiceDidConnect(port: UInt16) {
        RGLog.info("[CxrClient] audio upload tcp connected, port: \(port)")
    }

    func audioUploadServiceDidStop() {
        RGLog.info("[CxrClient] audio upload stopped")
    }

    func audioUploadServiceDidFail(error: Error) {
        if (error as NSError).code == -1001 {
            RGLog.warn("[CxrClient] heartbeat timeout, stop audio upload")
        }
        RGLog.error("[CxrClient] audio upload error: \(error.localizedDescription)")
    }

    func audioUploadServiceSendPing() {
        sendPing()
    }
}

extension RGCxrClientImpl: RGCxrClientCustomViewPayloadUploadServiceDelegate {

    func customViewPayloadUploadServiceDidConnect(requestId: Int, port: UInt16) {
        RGLog.info("[CxrClient] custom view payload upload tcp connected, requestId: \(requestId), port: \(port)")
    }

    func customViewPayloadUploadServiceDidSend(requestId: Int) {
        RGLog.info("[CxrClient] custom view payload data sent, requestId: \(requestId)")
        pendingCustomViewTextPayloads.removeValue(forKey: requestId)
    }

    func customViewPayloadUploadServiceDidStop() {
        RGLog.info("[CxrClient] custom view payload upload stopped")
    }

    func customViewPayloadUploadServiceDidFail(requestId: Int, error: Error) {
        RGLog.error("[CxrClient] custom view payload upload error, requestId: \(requestId), error: \(error.localizedDescription)")
        pendingCustomViewTextPayloads.removeValue(forKey: requestId)
        cancelCustomViewTimeout(requestId: requestId)
        let member = pendingCustomViewCallbackMembers.removeValue(forKey: requestId) ?? "customView"
        if let callback = pendingCustomViewBoolCallbacks.removeValue(forKey: requestId) {
            logPublicCallback(member, requestId: requestId, "success: false, reason: \(error.localizedDescription)")
            callback(false)
        } else if let callback = pendingCustomViewOpenCallbacks.removeValue(forKey: requestId) {
            logPublicCallback("openCustomView", requestId: requestId, "success: false, errorCode: nil, reason: \(error.localizedDescription)")
            callback(false, nil)
        }
    }

    func customViewPayloadUploadServiceSendPing() {
        sendPing()
    }
}

extension RGCxrClientImpl: RGCxrClientCustomCmdStreamUploadServiceDelegate {

    func customCmdStreamUploadServiceDidConnect(requestId: Int, port: UInt16) {
        RGLog.info("[CxrClient] custom cmd stream upload tcp connected, requestId: \(requestId), port: \(port)")
    }

    func customCmdStreamUploadServiceDidSend(requestId: Int) {
        RGLog.info("[CxrClient] custom cmd stream data sent, requestId: \(requestId)")
    }

    func customCmdStreamUploadServiceDidStop() {
        RGLog.info("[CxrClient] custom cmd stream upload stopped")
    }

    func customCmdStreamUploadServiceDidFail(requestId: Int, error: Error) {
        RGLog.error("[CxrClient] custom cmd stream upload error, requestId: \(requestId), error: \(error.localizedDescription)")
        pendingCustomCmdStreamPayloads.removeValue(forKey: requestId)
        cancelCustomCmdTimeout(requestId: requestId)
        let callback = pendingCustomCmdCallbacks.removeValue(forKey: requestId)
        pendingCustomCmdCallbackMembers.removeValue(forKey: requestId)
        logPublicCallback("sendCustomCmdStream", requestId: requestId, "success: false, payloadSize: 0, errorCode: nil, errorMsg: \(error.localizedDescription)")
        callback?(false, nil, nil, error.localizedDescription)
    }

    func customCmdStreamUploadServiceSendPing() {
        sendPing()
    }
}

extension RGCxrClientImpl: RGCxrClientApkUploadServiceDelegate {

    func apkUploadServiceDidConnect(requestId: Int, port: UInt16) {
        RGLog.info("[CxrClient] apk upload tcp connected, requestId: \(requestId), port: \(port)")
    }

    func apkUploadServiceDidSend(requestId: Int) {
        RGLog.info("[CxrClient] apk upload data sent, requestId: \(requestId)")
    }

    func apkUploadServiceDidStop() {
        RGLog.info("[CxrClient] apk upload stopped")
    }

    func apkUploadServiceDidFail(requestId: Int, error: Error) {
        RGLog.error("[CxrClient] apk upload error, requestId: \(requestId), error: \(error.localizedDescription)")
        pendingInstallAppPayloads.removeValue(forKey: requestId)
        pendingThirdAppRequestKinds.removeValue(forKey: requestId)
        let callback = pendingThirdAppCallbacks.removeValue(forKey: requestId)
        logPublicCallback("installApp", requestId: requestId, "success: false, reason: \(error.localizedDescription)")
        callback?(false)
    }

    func apkUploadServiceSendPing() {
        sendPing()
    }
}
