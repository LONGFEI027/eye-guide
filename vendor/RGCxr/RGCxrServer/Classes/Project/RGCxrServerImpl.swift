//
//  RGCxrServerImpl.swift
//  RGCxrServer
//
//  Created by Ginger on 2026/3/2.
//

import Foundation
import Combine
import RGCoreKit
import RGCxrKit

internal final class RGCxrServerImpl: RGCxrServer {

    internal static let shared = RGCxrServerImpl()

    var onGetPicConfig: (() -> (String, String))?
    var onGetVersion: (() -> Int)?
    var onGetDeviceInfo: (() -> RGCxrDeviceInfo?)?
    var onGetWearingSwitch: (() -> Bool)?
    var onGetSceneStatus: (() -> RGCxrServerSceneStatusSnapshot?)?
    var onGetScreenOn: (() -> Bool?)?

    private let eventSubject = PassthroughSubject<RGCxrServerEvent, Never>()
    private let sessionInfoSubject = PassthroughSubject<RGCxrSessionInfo, Never>()

    public var eventPublisher: AnyPublisher<RGCxrServerEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    public var sessionInfoPublisher: AnyPublisher<RGCxrSessionInfo, Never> {
        sessionInfoSubject.eraseToAnyPublisher()
    }

    public var activeSession: RGCxrSessionInfo? {
        RGCxrSessionManager.shared.activeSession.map { internalSession in
            RGCxrSessionInfo(
                bundleId: internalSession.bundleId,
                sessionId: internalSession.sessionId,
                state: internalSession.isActive ? .active : .inactive,
                createdAt: internalSession.createdAt
            )
        }
    }

    public var allSessions: [RGCxrSessionInfo] {
        RGCxrSessionManager.shared.allSessions.map { internalSession in
            RGCxrSessionInfo(
                bundleId: internalSession.bundleId,
                sessionId: internalSession.sessionId,
                state: internalSession.isActive ? .active : .inactive,
                createdAt: internalSession.createdAt
            )
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var pendingStartGatt = false
    private var lastCustomViewRunning: Bool?
    private var lastSceneStatus: RGCxrServerSceneStatusSnapshot?
    private var lastSessionLifecycleState: String?
    private var activeCustomAppPackageName: String?
    /// Client 发起 changeAudioSceneId 时暂存 requestId，眼镜通过 notify 回包后再转发给 Client
    private var pendingChangeAudioSceneClientRequestId: Int?

    private let photoTransferService = RGCxrPhotoTransferService.shared
    private let audioPlaybackService = RGCxrAudioPlaybackService.shared
    private let apkUploadService = RGCxrApkUploadService.shared
    private let apkInstallService = RGCxrApkInstallService.shared
    private let customCmdStreamUploadService = RGCxrCustomCmdStreamUploadService.shared
    private let customViewPayloadUploadService = RGCxrCustomViewPayloadUploadService.shared
    private let thirdAppService = RGCxr3rdAppService.shared
    private let customViewService = RGCxrCustomViewService.shared

    private init() {
        setupAuthManagerObserver()
        setupSessionManagerObserver()
        setupAudioForwardingService()
        setupLocalChannelServices()
        setupCxrKitBindings()
        sinkNotify()
        RGLog.info("[CxrServer] Server initialized")
    }

    private func setupLocalChannelServices() {
        photoTransferService.delegate = self
        audioPlaybackService.delegate = self
        apkUploadService.delegate = self
        apkInstallService.delegate = self
        customCmdStreamUploadService.delegate = self
        customViewPayloadUploadService.delegate = self
        thirdAppService.delegate = self
        customViewService.delegate = self
    }

    public func revokeAuthorization(for bundleId: String) {
        RGLog.info("[CxrServer] 撤销应用授权: \(bundleId)")
        RGCxrAuthManager.shared.revokeAuthorization(for: bundleId)
        RGCxrSessionManager.shared.revokeSession(for: bundleId)
    }

    public func revokeAllAuthorizations() {
        RGLog.info("[CxrServer] 撤销全部应用授权")
        RGCxrAuthManager.shared.revokeAllAuthorizations()
        RGCxrSessionManager.shared.clearAllSessions()
    }

    func handleOpenURL(_ url: URL) -> Bool {
        RGCxrAuthManager.shared.handleURLScheme(url)
    }

    func canHandleURL(_ url: URL) -> Bool {
        RGCxrAuthManager.shared.canHandleURL(url)
    }

    func setActiveDeviceNameProvider(_ provider: @escaping () -> String?) {
        RGCxrAuthManager.shared.activeDeviceNameProvider = provider
    }

    func sinkNotify() {
        RGCxrKit.shared.dataNotifyPublisher
            .sink { [weak self] res in
                guard let self else { return }
                RGLog.info(res.cmd)
                if res.enumCmd != nil {
                    return
                }
                if let msg = self.buildCxrNotify(res) {
                    self.sendMessageToClient(msg)
                }
            }
            .store(in: &cancellables)
    }

    public func handleAudioStreamStart(_ info: RGCxrAudioStreamStartInfo) {
        RGCxrAudioForwardingService.shared.handleAudioStreamStart(codec: info.codec, type: info.type, channels: info.channels)
    }

    public func handleAudioStreamData(_ streamData: RGCxrAudioStreamData) {
        RGCxrAudioForwardingService.shared.handleAudioStreamData(data: streamData.data, timestamp: streamData.timestamp)
    }

    public func updateSceneStatus(_ status: RGCxrServerSceneStatusSnapshot) {
        handleSceneStatusChanged(status)
    }

    public func updateScreenOn(_ screenOn: Bool) {
        if screenOn {
            handleScreenResumed()
        } else {
            sendSessionLifecycleIfChanged(state: "paused", reason: "screenOffGlass")
        }
    }

    public func handleIncomingMessage(_ message: String, token: String?) -> Bool {
        guard validateIncomingToken(token) else {
            RGLog.warn("[CxrServer] 丢弃消息：token 无效或非活跃 session")
            return false
        }

        guard let payloadData = message.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData, options: []) as? [String: Any] else {
            RGLog.warn("[CxrServer] 丢弃消息：payload 不是有效 JSON")
            return false
        }

        if let incomingBundleId = payload["bundleId"] as? String,
           let activeBundleId = RGCxrSessionManager.shared.activeSession?.bundleId,
           incomingBundleId != activeBundleId {
            RGLog.warn("[CxrServer] 丢弃消息：bundleId 与活跃 session 不一致")
            return false
        }

        guard let type = payload["type"] as? String else {
            RGLog.warn("[CxrServer] 丢弃消息：缺少 type 字段")
            return false
        }

        switch type {
        case "ping":
            RGLog.debug("[CxrServer] 收到 ping，回复 pong")
            if let pong = buildPong() {
                sendMessageToClient(pong)
            }
        case "pong":
            RGLog.debug("[CxrServer] 收到保活消息: \(type)")
        case "sendCustomViewIcons":
            return handleCustomViewIcons(payload)
        case "sendCustomCmd":
            return handleSendCustomCmd(payload)
        case "sendCustomCmdStream":
            return handleSendCustomCmdStream(payload)
        case "getDeviceInfo":
            return handleGetDeviceInfo(payload)
        case "getWearingSwitch":
            return handleGetWearingSwitch(payload)
        case "setBrightness":
            return handleSetBrightness(payload)
        case "getBrightness":
            return handleGetBrightness(payload)
        case "setVolume":
            return handleSetVolume(payload)
        case "getVolume":
            return handleGetVolume(payload)
        case "interruptAiWake":
            return handleInterruptAiWake(payload)
        case "openCustomView":
            return handleOpenCustomView(payload)
        case "updateCustomView":
            return handleUpdateCustomView(payload)
        case "closeCustomView":
            return handleCloseCustomView(payload)
        case "startRecord":
            return handleStartRecord(payload)
        case "stopRecord":
            return handleStopRecord(payload)
        case "startPlayAudio":
            return handleStartPlayAudio(payload)
        case "stopPlayAudio":
            return handleStopPlayAudio(payload)
        case "takePhoto":
            return handleTakePhoto(payload)
        case "takePhotoWithData":
            return handleTakePhotoWithData(payload)
        case "queryApp":
            return handleQueryApp(payload)
        case "openApp":
            return handleOpenApp(payload)
        case "stopApp":
            return handleStopApp(payload)
        case "uninstallApp":
            return handleUninstallApp(payload)
        case "installApp":
            return handleInstallApp(payload)
        case "changeAudioSceneId":
            return handleChangeAudioSceneId(payload)
        default:
            RGLog.debug("[CxrServer] 收到业务消息: \(type)")
        }

        return true
    }

    // 眼镜的通知，根据场景判断是否要转发给client或者做一些逻辑
    public func handleNotify(cmd: String,
                             subCmd: String,
                             responseData: Any?,
                             responseDataEx: Any?,
                             reqId: Int32,
                             status: Int32,
                             caps: Any?) {
        if cmd == RGCxrCmd.Sys.rawValue,
           subCmd == RGCxrSubCmd.Sys_App_Resume_Change.rawValue {
            guard let packageName = responseData as? String else {
                RGLog.warn("[CxrServer] Sys_App_Resume_Change 参数不完整: \(String(describing: responseData))")
                return
            }
            if let msg = buildAppResumeChange(packageName: packageName) {
                sendMessageToClient(msg)
            }
            return
        }

        /// Sys_ChangeAudioSceneId 仅通过 notify 回包（非 request/response）
        if cmd == RGCxrCmd.Sys.rawValue,
           subCmd == RGCxrSubCmd.Sys_ChangeAudioSceneId.rawValue {
            guard let info = responseData as? String,
                  let jsonData = info.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
                RGLog.warn("[CxrServer] Sys_ChangeAudioSceneId notify 解析失败: \(String(describing: responseData))")
                return
            }
            let audioSceneId = (jsonObject["audioSceneId"] as? Int) ?? 0
            let success = (jsonObject["success"] as? Bool) ?? false
            let clientRequestId = pendingChangeAudioSceneClientRequestId
            pendingChangeAudioSceneClientRequestId = nil
            if let msg = buildChangeAudioSceneIdResult(requestId: clientRequestId, audioSceneId: audioSceneId, success: success) {
                sendMessageToClient(msg)
            }
            return
        }

        if cmd == RGCxrCmd.Med.rawValue,
           subCmd == RGCxrSubCmd.Sync_Start.rawValue {
            apkInstallService.handleSyncStart(responseData)
            return
        }

        if cmd == RGCxrCmd.Sys.rawValue,
           subCmd == RGCxrSubCmd.Sys_Apk_Install_Succeed.rawValue {
            apkInstallService.handleInstallResult(success: true)
            return
        }

        if cmd == RGCxrCmd.Sys.rawValue,
           subCmd == RGCxrSubCmd.Sys_Apk_Install_Failed.rawValue {
            apkInstallService.handleInstallResult(success: false)
            return
        }

        if cmd == RGCxrCmd.Med.rawValue,
           subCmd == RGCxrSubCmd.Med_Take_Photo_Url.rawValue {
            RGCxrKit.shared.send(cmd: .Med, subCmd: .UnSync_Count)
            return
        }

        if cmd == RGCxrCmd.Dev.rawValue {
            if subCmd == RGCxrSubCmd.Dev_Screen_Status.rawValue,
               let screenOn = parseScreenOn(responseData) {
                updateScreenOn(screenOn)
            }
            if subCmd == RGCxrSubCmd.Dev_WearingStatus.rawValue,
               let wearing = parseWearingStatus(responseData) {
                if let msg = buildWearingStatusNotify(wearing) {
                    sendMessageToClient(msg)
                }
            }
            if subCmd == RGCxrSubCmd.Dev_BatteryChanged.rawValue ||
                subCmd == RGCxrSubCmd.Dev_GlassSound.rawValue ||
                subCmd == RGCxrSubCmd.Dev_GlassBrightness.rawValue ||
                subCmd == RGCxrSubCmd.Dev_WearingStatus.rawValue {
                if let msg = buildDeviceInfoNotify(onGetDeviceInfo?()) {
                    sendMessageToClient(msg)
                }
            }
            return
        }

        if cmd == RGCxrCmd.Ai.rawValue {
            if subCmd == RGCxrSubCmd.Ai_Waked.rawValue,
               let interrupt = parseAiWakeInterrupt(responseData) {
                if let msg = buildAiWakeInterruptNotify(interrupt) {
                    sendMessageToClient(msg)
                }
                if !interrupt {
                    sendSessionLifecycleIfChanged(state: "paused", reason: "aiStart")
                }
                return
            }
            if subCmd == RGCxrSubCmd.Ai_SceneStatus.rawValue {
                if let info = responseData as? String,
                   let jsonData = info.data(using:.utf8),
                   let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                    handleSceneStatusChanged(RGCxrServerSceneStatusSnapshot(jsonObject: jsonObject))
                }
            }
        }
    }

    private func setupAuthManagerObserver() {
        RGCxrAuthManager.shared.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleAuthManagerEvent(event)
            }
            .store(in: &cancellables)
    }

    private func setupSessionManagerObserver() {
        RGCxrSessionManager.shared.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleSessionManagerEvent(event)
            }
            .store(in: &cancellables)
    }

    private func setupAudioForwardingService() {
        RGCxrAudioForwardingService.shared.delegate = self
    }

    private func handleCustomViewIcons(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] sendCustomViewIcons 参数不完整: \(payload)")
            return false
        }
        if let icons = data["icons"] as? String, !icons.isEmpty {
            customViewService.sendIcons(requestId: requestId, icons: icons)
            return true
        }
        customViewPayloadUploadService.prepare(requestId: requestId, operation: .sendIcons)
        return true
    }

    private func handleSendCustomCmd(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let cmd = data["cmd"] as? String,
              !cmd.isEmpty else {
            RGLog.warn("[CxrServer] sendCustomCmd 参数不完整: \(payload)")
            return false
        }
        let requestId = data["requestId"] as? Int
        let payloadBase64 = data["payload"] as? String
        let payloadData: Data? = {
            guard let payloadBase64, !payloadBase64.isEmpty else { return nil }
            guard let decoded = Data(base64Encoded: payloadBase64) else {
                RGLog.warn("[CxrServer] sendCustomCmd payload base64 解码失败")
                return nil
            }
            return decoded
        }()
        RGCxrKit.shared.sendData(cmd: cmd, data: payloadData) { [weak self] response in
            guard let self else { return }
            let msg = self.buildSendCustomCmdResult(requestId: requestId, response: response)
            if let msg {
                self.sendMessageToClient(msg)
            }
        }
        return true
    }

    private func decodeBase64Payload(_ payloadBase64: String?) -> Data? {
        guard let payloadBase64, !payloadBase64.isEmpty else { return nil }
        guard let decoded = Data(base64Encoded: payloadBase64) else {
            RGLog.warn("[CxrServer] payload base64 解码失败")
            return nil
        }
        return decoded
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

    private func responseSucceeded(_ response: RGCxrBaseResponse) -> Bool {
        if response is RGCxrErrorResponse {
            return false
        }
        return response.status == 0 || response.status == 1
    }

    private func handleSendCustomCmdStream(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let cmd = data["cmd"] as? String,
              !cmd.isEmpty else {
            RGLog.warn("[CxrServer] sendCustomCmdStream 参数不完整: \(payload)")
            return false
        }
        let payloadData = decodeBase64Payload(data["payload"] as? String)
        customCmdStreamUploadService.prepare(requestId: requestId, cmd: cmd, payload: payloadData)
        return true
    }

    private func handleGetDeviceInfo(_ payload: [String: Any]) -> Bool {
        let data = payload["data"] as? [String: Any]
        let requestId = data?["requestId"] as? Int
        if let msg = buildDeviceInfoResult(requestId: requestId, deviceInfo: onGetDeviceInfo?()) {
            sendMessageToClient(msg)
        }
        return true
    }

    private func handleGetWearingSwitch(_ payload: [String: Any]) -> Bool {
        let data = payload["data"] as? [String: Any]
        let requestId = data?["requestId"] as? Int
        let switchOn = onGetWearingSwitch?() ?? false
        if let msg = buildWearingSwitchResult(requestId: requestId, switchOn: switchOn) {
            sendMessageToClient(msg)
        }
        return true
    }

    private func handleSetBrightness(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let level = intValue(from: data["level"]) else {
            RGLog.warn("[CxrServer] setBrightness 参数不完整: \(payload)")
            return false
        }
        guard (0...15).contains(level) else {
            if let msg = buildDeviceControlResult(type: "setBrightnessResult",
                                                  requestId: requestId,
                                                  success: false,
                                                  levelKey: nil,
                                                  level: nil) {
                sendMessageToClient(msg)
            }
            return true
        }

        RGCxrKit.shared.send(cmd: .Dev, subCmd: .Dev_GlassBrightness, data: Int32(level)) { [weak self] response in
            guard let self else { return }
            let success = self.responseSucceeded(response)
            if let msg = self.buildDeviceControlResult(type: "setBrightnessResult",
                                                       requestId: requestId,
                                                       success: success,
                                                       levelKey: nil,
                                                       level: nil) {
                self.sendMessageToClient(msg)
            }
        }
        return true
    }

    private func handleGetBrightness(_ payload: [String: Any]) -> Bool {
        let data = payload["data"] as? [String: Any]
        let requestId = data?["requestId"] as? Int
        let level = onGetDeviceInfo?()?.brightness
        if let msg = buildDeviceControlResult(type: "getBrightnessResult",
                                              requestId: requestId,
                                              success: level != nil,
                                              levelKey: "brightness",
                                              level: level) {
            sendMessageToClient(msg)
        }
        return true
    }

    private func handleSetVolume(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let level = intValue(from: data["level"]) else {
            RGLog.warn("[CxrServer] setVolume 参数不完整: \(payload)")
            return false
        }
        guard (0...15).contains(level) else {
            if let msg = buildDeviceControlResult(type: "setVolumeResult",
                                                  requestId: requestId,
                                                  success: false,
                                                  levelKey: nil,
                                                  level: nil) {
                sendMessageToClient(msg)
            }
            return true
        }

        RGCxrKit.shared.send(cmd: .Dev, subCmd: .Dev_GlassSound, data: Int32(level)) { [weak self] response in
            guard let self else { return }
            let success = self.responseSucceeded(response)
            if let msg = self.buildDeviceControlResult(type: "setVolumeResult",
                                                       requestId: requestId,
                                                       success: success,
                                                       levelKey: nil,
                                                       level: nil) {
                self.sendMessageToClient(msg)
            }
        }
        return true
    }

    private func handleGetVolume(_ payload: [String: Any]) -> Bool {
        let data = payload["data"] as? [String: Any]
        let requestId = data?["requestId"] as? Int
        let level = onGetDeviceInfo?()?.sound
        if let msg = buildDeviceControlResult(type: "getVolumeResult",
                                              requestId: requestId,
                                              success: level != nil,
                                              levelKey: "volume",
                                              level: level) {
            sendMessageToClient(msg)
        }
        return true
    }

    private func handleInterruptAiWake(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let interruptWake = data["interruptWake"] as? Bool else {
            RGLog.warn("[CxrServer] interruptAiWake 参数不完整: \(payload)")
            return false
        }
        let requestId = data["requestId"] as? Int
        let version = onGetVersion?() ?? 0
        guard version >= 3200 else {
            if let msg = buildInterruptAiWakeResult(requestId: requestId, success: false) {
                sendMessageToClient(msg)
            }
            return true
        }

        let commandData = ["status": interruptWake ? 1 : 0].toJsonString()
        RGCxrKit.shared.send(cmd: .Ai, subCmd: .Ai_Interrupt_Wake, data: commandData)
        if let msg = buildInterruptAiWakeResult(requestId: requestId, success: true) {
            sendMessageToClient(msg)
        }
        return true
    }

    private func handleOpenCustomView(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] openCustomView 参数不完整: \(payload)")
            return false
        }
        if let view = data["view"] as? String, !view.isEmpty {
            customViewService.openCustomView(requestId: requestId, view: view)
            return true
        }
        customViewPayloadUploadService.prepare(requestId: requestId, operation: .open)
        return true
    }

    private func handleUpdateCustomView(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] updateCustomView 参数不完整: \(payload)")
            return false
        }
        if let view = data["view"] as? String, !view.isEmpty {
            customViewService.updateCustomView(requestId: requestId, view: view)
            return true
        }
        customViewPayloadUploadService.prepare(requestId: requestId, operation: .update)
        return true
    }

    private func handleCloseCustomView(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] closeCustomView 参数不完整: \(payload)")
            return false
        }
        customViewService.closeCustomView(requestId: requestId)
        return true
    }

    private func handleStartRecord(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let recordType = data["type"] as? String,
              let codecValue = data["codec"] as? Int,
              let modeValue = data["mode"] as? Int else {
            RGLog.warn("[CxrServer] startRecord 参数不完整: \(payload)")
            return false
        }
        RGCxrKit.shared.openAudioRecord(type: recordType, codec: UInt32(codecValue), mode: UInt32(modeValue))
        return true
    }

    private func handleStopRecord(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let recordType = data["type"] as? String else {
            RGLog.warn("[CxrServer] stopRecord 参数不完整: \(payload)")
            return false
        }
        RGCxrKit.shared.closeAudioRecord(type: recordType)
        return true
    }

    private func handleStartPlayAudio(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let codecValue = data["codec"] as? Int else {
            RGLog.warn("[CxrServer] startPlayAudio 参数不完整: \(payload)")
            return false
        }

        // mock 播放器：开启本地 TCP 端口，等待 client 连接后推送 feedAudio
        let metadata: [String: Any] = [
            "codec": codecValue
        ]
        audioPlaybackService.start(metadata: metadata)
        return true
    }

    private func handleStopPlayAudio(_ payload: [String: Any]) -> Bool {
        RGLog.info("[CxrServer] stopPlayAudio")
        audioPlaybackService.stop()
        return true
    }

    private func handleTakePhotoWithData(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let width = data["width"] as? Int,
              let height = data["height"] as? Int,
              let quality = data["quality"] as? Int else {
            RGLog.warn("[CxrServer] setPictureConfig 参数不完整: \(payload)")
            return false
        }

        // 提前准备本地通道，端口 ready 后会通过 localChannelStart 通知 client
        let metadata: [String: Any] = [
            "width": width,
            "height": height,
            "quality": quality
        ]
        photoTransferService.prepare(metadata: metadata)
        RGCxrKit.shared.send(cmd: .Med, subCmd: .Med_Take_Photo_Global, data: ["width": width, "height": height, "quality": quality].toJsonString())
        return true
    }

    private func handleTakePhoto(_ payload: [String: Any]) -> Bool {
        if let version = onGetVersion?(),
           version >= 3016 {
            let data = [
                "name": "take_picture",
                "open": true
            ] as [String : Any]
            RGCxrKit.shared.send(cmd: .Sys, subCmd: .Scene_Control, data: data.toJsonString())
            return true
        } else if let config = onGetPicConfig?() {
            RGCxrKit.shared.send(cmd: .Med, subCmd: .Med_Take_Photo_Url, data: ["width": config.0, "height": config.1, "quality": "100"].toJsonString())
            return true
        } else {
            return false
        }
    }

    private func handleSetPictureConfig(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let width = data["width"] as? Int,
              let height = data["height"] as? Int else {
            RGLog.warn("[CxrServer] setPictureConfig 参数不完整: \(payload)")
            return false
        }
        let params = [
            ["key": "settings_photo_width", "value": width],
            ["key": "settings_photo_height", "value": height]
        ]
        RGCxrKit.shared.send(cmd: .Settings, subCmd: .Settings_Update, data: params.toString())
        return true
    }

    private func handleQueryApp(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let packageName = data["packageName"] as? String,
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] queryApp 参数不完整: \(payload)")
            return false
        }
        thirdAppService.queryApp(requestId: requestId, packageName: packageName)
        return true
    }

    private func handleOpenApp(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let packageName = data["packageName"] as? String,
              let activityName = data["activityName"] as? String,
              let url = data["url"] as? String,
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] openApp 参数不完整: \(payload)")
            return false
        }
        thirdAppService.openApp(requestId: requestId, packageName: packageName, activityName: activityName, url: url)
        return true
    }

    private func handleStopApp(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let packageName = data["packageName"] as? String,
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] stopApp 参数不完整: \(payload)")
            return false
        }
        thirdAppService.stopApp(requestId: requestId, packageName)
        return true
    }

    private func handleUninstallApp(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let packageName = data["packageName"] as? String,
              let requestId = data["requestId"] as? Int else {
            RGLog.warn("[CxrServer] uninstallApp 参数不完整: \(payload)")
            return false
        }
        thirdAppService.uninstallApp(requestId: requestId, packageName)
        return true
    }

    private func handleInstallApp(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let requestId = data["requestId"] as? Int,
              let fileName = data["fileName"] as? String,
              !fileName.isEmpty else {
            RGLog.warn("[CxrServer] installApp 参数不完整: \(payload)")
            return false
        }
        apkUploadService.prepare(requestId: requestId, fileName: fileName)
        return true
    }

    private func handleChangeAudioSceneId(_ payload: [String: Any]) -> Bool {
        guard let data = payload["data"] as? [String: Any],
              let audioSceneId = data["audioSceneId"] as? Int else {
            RGLog.warn("[CxrServer] changeAudioSceneId 参数不完整: \(payload)")
            return false
        }
        let requestId = data["requestId"] as? Int
        pendingChangeAudioSceneClientRequestId = requestId
        let reqPayload = ["audioSceneId": audioSceneId].toJsonString()
        /// 眼镜侧通过 notify 返回结果，不走 send 的 onResponse
        RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_ChangeAudioSceneId, data: reqPayload, onResponse: nil)
        return true
    }

    private func validateIncomingToken(_ token: String?) -> Bool {
        guard let token, !token.isEmpty,
              let activeSession = RGCxrSessionManager.shared.activeSession else {
            return false
        }
        return activeSession.token == token
    }

    private func handleAuthManagerEvent(_ event: RGCxrAuthEvent) {
        switch event {
        case .authorizationRequired(let request, let completion):
            RGLog.info("[CxrServer] 收到鉴权请求，需要用户确认: \(request.bundleId)")
            eventSubject.send(.authorizationRequired(request: request, completion: completion))

        case .authorized(let bundleId, let token):
            RGLog.info("[CxrServer] 鉴权成功: \(bundleId)")
            eventSubject.send(.authorized(bundleId: bundleId, token: token))
            handleAuthorized()

        case .denied(let bundleId, let error):
            RGLog.info("[CxrServer] 鉴权被拒绝: \(bundleId)")
            eventSubject.send(.denied(bundleId: bundleId, error: error))

        case .expired(let bundleId):
            RGLog.info("[CxrServer] 鉴权已过期: \(bundleId)")
        }
    }

    private func handleSessionManagerEvent(_ event: RGCxrSessionEvent) {
        switch event {
        case .sessionCreated(let session):
            RGLog.info("[CxrServer] Session 创建: \(session.bundleId)")

        case .sessionActivated(let session):
            RGLog.info("[CxrServer] Session 激活: \(session.bundleId)")
            let info = RGCxrSessionInfo(
                bundleId: session.bundleId,
                sessionId: session.sessionId,
                state: .active,
                createdAt: session.createdAt
            )
            sessionInfoSubject.send(info)

        case .sessionDeactivated(let session):
            RGLog.info("[CxrServer] Session 失活: \(session.bundleId)")
            let info = RGCxrSessionInfo(
                bundleId: session.bundleId,
                sessionId: session.sessionId,
                state: .inactive,
                createdAt: session.createdAt
            )
            sessionInfoSubject.send(info)

        case .sessionRevoked(let bundleId):
            RGLog.info("[CxrServer] Session 撤销: \(bundleId)")
        }
    }

    private func handleAuthorized() {
        if RGCxrKit.shared.connectionStatus == .socketConnected {
            RGLog.info("[CxrServer] 当前已连接，直接启动 GATT Server")
            RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_Bt_Gatt_Server, data: "StartGatt")
        } else {
            RGLog.info("[CxrServer] 当前未连接，等待连接后启动 GATT Server")
            pendingStartGatt = true
        }
    }

    private func setupCxrKitBindings() {
        RGCxrKit.shared.connectionStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                if status, self.pendingStartGatt {
                    RGLog.info("[CxrServer] 连接成功，启动 GATT Server")
                    RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_Bt_Gatt_Server, data: "StartGatt")
                    self.pendingStartGatt = false
                }
            }
            .store(in: &cancellables)

        RGCxrKit.shared.startAudioStreamPublisher
            .sink { [weak self] (codec: Int32, type: String, channels: UInt32) in
                self?.handleAudioStreamStart(
                    RGCxrAudioStreamStartInfo(codec: codec, type: type, channels: channels)
                )
            }
            .store(in: &cancellables)

        RGCxrKit.shared.audioStreamPublisher
            .sink { [weak self] (data: Data, timestamp: UInt64) in
                self?.handleAudioStreamData(
                    RGCxrAudioStreamData(data: data, timestamp: timestamp)
                )
            }
            .store(in: &cancellables)

        RGCxrKit.shared.dataNotifyPublisher
            .sink { [weak self] response in
                guard let self = self else { return }
                if response.enumCmd == .Sys,
                   response.enumSubCmd == .Sys_Bt_Gatt_Msg,
                   let message = response.responseData as? String,
                   let token = response.responseDataEx as? String {
                    _ = self.handleIncomingMessage(message, token: token)
                } else {
                    self.handleNotify(
                        cmd: response.cmd,
                        subCmd: response.subCmd,
                        responseData: response.responseData,
                        responseDataEx: response.responseDataEx,
                        reqId: response.reqId,
                        status: response.status,
                        caps: response.caps
                    )
                }
            }
            .store(in: &cancellables)

        RGCxrKit.shared.streamPublisher
            .sink { [weak self] response in
                guard let self else { return }
                if response.enumSubCmd == .Med_Take_Photo_Global,
                   let data = response.streamData {
                    self.photoTransferService.onPhotoDataReady(data)
                }
            }
            .store(in: &cancellables)
    }

    private func sendMessageToClient(_ message: String) {
        RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_Bt_Gatt_Msg, data: message)
    }
}

extension RGCxrServerImpl: RGCxrAudioForwardingDelegate {

    internal func audioForwardingDidStart(port: UInt16, codec: Int32, type: String, channels: UInt32) {
        RGLog.info("[CxrServer] Audio forwarding started on port \(port)")
        // 通过通用的本地通道启动消息通知客户端，这里约定 channelId 为 audio_down，mode 为 stream
        let metadata: [String: Any] = [
            "codec": codec,
            "type": type,
            "channels": channels
        ]
        if let msg = buildLocalChannelStart(
            channelId: "audio_down",
            port: port,
            mode: "stream",
            metadata: metadata
        ) {
            sendMessageToClient(msg)
        }
    }

    internal func audioForwardingDidStop() {
        RGLog.info("[CxrServer] Audio forwarding stopped")
        if let msg = buildLocalChannelStop(channelId: "audio_down") {
            sendMessageToClient(msg)
        }
    }

    internal func audioForwardingDidConnect(clientBundleId: String) {
        RGLog.info("[CxrServer] Audio client connected: \(clientBundleId)")
    }

    internal func audioForwardingDidDisconnect(clientBundleId: String) {
        RGLog.info("[CxrServer] Audio client disconnected: \(clientBundleId)")
    }
}

extension RGCxrServerImpl: RGCxrPhotoTransferDelegate {

    internal func photoTransferDidStart(port: UInt16, metadata: [String: Any]) {
        RGLog.info("[CxrServer] Photo transfer started on port \(port)")
        if let msg = buildLocalChannelStart(
            channelId: "photo",
            port: port,
            mode: "chunk",
            metadata: metadata
        ) {
            sendMessageToClient(msg)
        }
    }

    internal func photoTransferDidStop() {
        RGLog.info("[CxrServer] Photo transfer stopped")
        if let msg = buildLocalChannelStop(channelId: "photo") {
            sendMessageToClient(msg)
        }
    }

    internal func photoTransferHeartbeat() {
        if let msg = buildPing() {
            sendMessageToClient(msg)
        }
    }
}

extension RGCxrServerImpl: RGCxrCustomViewPayloadUploadDelegate {

    internal func customViewPayloadUploadDidStart(requestId: Int, port: UInt16, metadata: [String: Any]) {
        RGLog.info("[CxrServer] Custom view payload upload started on port \(port), requestId: \(requestId)")
        if let msg = buildLocalChannelStart(
            channelId: "custom_view_upload",
            port: port,
            mode: "chunk",
            metadata: metadata
        ) {
            sendMessageToClient(msg)
        }
    }

    internal func customViewPayloadUploadDidReceive(requestId: Int, operation: RGCxrCustomViewPayloadOperation, text: String) {
        RGLog.info("[CxrServer] Custom view payload received, requestId: \(requestId), op: \(operation.rawValue), size: \(text.utf8.count)")
        switch operation {
        case .sendIcons:
            customViewService.sendIcons(requestId: requestId, icons: text)
        case .open:
            customViewService.openCustomView(requestId: requestId, view: text)
        case .update:
            customViewService.updateCustomView(requestId: requestId, view: text)
        }
    }

    internal func customViewPayloadUploadDidAbort(requestId: Int, operation: RGCxrCustomViewPayloadOperation) {
        RGLog.warn("[CxrServer] Custom view payload upload aborted, requestId: \(requestId), op: \(operation.rawValue)")
        let type: String
        switch operation {
        case .sendIcons:
            type = "sendCustomViewIconsResult"
        case .open:
            type = "openCustomViewResult"
        case .update:
            type = "updateCustomViewResult"
        }
        if let msg = buildCustomViewResult(type: type, requestId: requestId, success: false, errorCode: nil) {
            sendMessageToClient(msg)
        }
    }

    internal func customViewPayloadUploadDidStop(requestId: Int?) {
        RGLog.info("[CxrServer] Custom view payload upload stopped, requestId: \(requestId ?? -1)")
        if let msg = buildLocalChannelStop(channelId: "custom_view_upload") {
            sendMessageToClient(msg)
        }
    }

    internal func customViewPayloadUploadHeartbeat() {
        if let msg = buildPing() {
            sendMessageToClient(msg)
        }
    }
}

extension RGCxrServerImpl: RGCxrCustomCmdStreamUploadDelegate {

    internal func customCmdStreamUploadDidStart(requestId: Int, port: UInt16, metadata: [String: Any]) {
        RGLog.info("[CxrServer] Custom cmd stream upload started on port \(port), requestId: \(requestId)")
        if let msg = buildLocalChannelStart(
            channelId: "custom_cmd_upload",
            port: port,
            mode: "chunk",
            metadata: metadata
        ) {
            sendMessageToClient(msg)
        }
    }

    internal func customCmdStreamUploadDidReceive(requestId: Int, cmd: String, payload: Data?, stream: Data) {
        RGLog.info("[CxrServer] Custom cmd stream received, cmd: \(cmd), requestId: \(requestId), size: \(stream.count)")
        RGCxrKit.shared.sendStream(cmd: cmd, args: payload, data: stream)
        if let msg = buildSendCustomCmdStreamResult(
            requestId: requestId,
            success: true,
            payload: nil,
            errorCode: nil,
            errorMsg: nil
        ) {
            sendMessageToClient(msg)
        }
    }

    internal func customCmdStreamUploadDidStop(requestId: Int?) {
        RGLog.info("[CxrServer] Custom cmd stream upload stopped, requestId: \(requestId ?? -1)")
        if let msg = buildLocalChannelStop(channelId: "custom_cmd_upload") {
            sendMessageToClient(msg)
        }
    }

    internal func customCmdStreamUploadHeartbeat() {
        if let msg = buildPing() {
            sendMessageToClient(msg)
        }
    }
}

extension RGCxrServerImpl: RGCxrAudioPlaybackDelegate {

    internal func audioPlaybackDidStart(port: UInt16, metadata: [String: Any]) {
        RGLog.info("[CxrServer] AudioUp playback started on port \(port)")
        if let msg = buildLocalChannelStart(
            channelId: "audio_up",
            port: port,
            mode: "stream",
            metadata: metadata
        ) {
            sendMessageToClient(msg)
        }
    }

    internal func audioPlaybackDidStop() {
        RGLog.info("[CxrServer] AudioUp playback stopped")
        if let msg = buildLocalChannelStop(channelId: "audio_up") {
            sendMessageToClient(msg)
        }
    }

    internal func audioPlaybackHeartbeat() {
        if let msg = buildPing() {
            sendMessageToClient(msg)
        }
    }
}

extension RGCxrServerImpl: RGCxr3rdAppServiceDelegate {
    internal func thirdAppServiceDidQueryApp(requestId: Int, packageName: String, installed: Bool) {
        if let msg = buildThirdAppResult(type: "queryAppResult", requestId: requestId, packageName: packageName, success: installed) {
            sendMessageToClient(msg)
        }
    }

    internal func thirdAppServiceDidOpenApp(requestId: Int, packageName: String, success: Bool) {
        if let msg = buildThirdAppResult(type: "openAppResult", requestId: requestId, packageName: packageName, success: success) {
            sendMessageToClient(msg)
        }
        if success {
            activeCustomAppPackageName = packageName
            sendSessionLifecycleIfChanged(state: "started", reason: "glassReady")
        }
    }

    internal func thirdAppServiceDidStopApp(requestId: Int, packageName: String, success: Bool) {
        if let msg = buildThirdAppResult(type: "stopAppResult", requestId: requestId, packageName: packageName, success: success) {
            sendMessageToClient(msg)
        }
        if success {
            if activeCustomAppPackageName == packageName {
                activeCustomAppPackageName = nil
            }
            sendSessionLifecycleIfChanged(state: "unavailable", reason: "glassIdle")
        }
    }

    internal func thirdAppServiceDidUninstallApp(requestId: Int, packageName: String, success: Bool) {
        if let msg = buildThirdAppResult(type: "uninstallAppResult", requestId: requestId, packageName: packageName, success: success) {
            sendMessageToClient(msg)
        }
        if success, activeCustomAppPackageName == packageName {
            activeCustomAppPackageName = nil
        }
    }
}

extension RGCxrServerImpl: RGCxrApkUploadDelegate {
    internal func apkUploadDidStart(requestId: Int, port: UInt16, metadata: [String: Any]) {
        RGLog.info("[CxrServer] APK upload started on port \(port), requestId: \(requestId)")
        if let msg = buildLocalChannelStart(
            channelId: "apk_upload",
            port: port,
            mode: "chunk",
            metadata: metadata
        ) {
            sendMessageToClient(msg)
        }
    }

    internal func apkUploadDidFinish(requestId: Int, success: Bool, localPath: String?) {
        RGLog.info("[CxrServer] APK upload finished, requestId: \(requestId), success: \(success), path: \(localPath ?? "-")")
        if success, let localPath {
            apkInstallService.startInstall(
                requestId: requestId,
                apkPath: localPath,
                fileName: URL(fileURLWithPath: localPath).lastPathComponent
            )
        } else if let msg = buildInstallAppResult(requestId: requestId, success: false, localPath: localPath) {
            sendMessageToClient(msg)
        }
    }

    internal func apkUploadDidStop(requestId: Int?) {
        RGLog.info("[CxrServer] APK upload stopped, requestId: \(requestId ?? -1)")
        if let msg = buildLocalChannelStop(channelId: "apk_upload") {
            sendMessageToClient(msg)
        }
    }

    internal func apkUploadHeartbeat() {
        if let msg = buildPing() {
            sendMessageToClient(msg)
        }
    }
}

extension RGCxrServerImpl: RGCxrApkInstallServiceDelegate {
    internal func apkInstallServiceDidFinish(requestId: Int, success: Bool) {
        if let msg = buildInstallAppResult(requestId: requestId, success: success, localPath: nil) {
            sendMessageToClient(msg)
        }
    }
}

extension RGCxrServerImpl: RGCxrCustomViewServiceDelegate {
    internal func customViewServiceDidSendIcons(requestId: Int, success: Bool) {
        if let msg = buildCustomViewResult(type: "sendCustomViewIconsResult", requestId: requestId, success: success, errorCode: nil) {
            sendMessageToClient(msg)
        }
    }

    internal func customViewServiceDidOpen(requestId: Int, success: Bool, errorCode: Int?) {
        if let msg = buildCustomViewResult(type: "openCustomViewResult", requestId: requestId, success: success, errorCode: errorCode) {
            sendMessageToClient(msg)
        }
        if success {
            sendCustomViewRunningIfChanged(true)
            sendSessionLifecycleIfChanged(state: "started", reason: "glassReady")
        }
    }

    internal func customViewServiceDidUpdate(requestId: Int, success: Bool) {
        if let msg = buildCustomViewResult(type: "updateCustomViewResult", requestId: requestId, success: success, errorCode: nil) {
            sendMessageToClient(msg)
        }
    }

    internal func customViewServiceDidClose(requestId: Int, success: Bool) {
        if let msg = buildCustomViewResult(type: "closeCustomViewResult", requestId: requestId, success: success, errorCode: nil) {
            sendMessageToClient(msg)
        }
        if success {
            sendCustomViewRunningIfChanged(false)
            sendSessionLifecycleIfChanged(state: "unavailable", reason: "glassIdle")
        }
    }
}

private extension RGCxrServerSceneStatusSnapshot {
    init(jsonObject: [String: Any]) {
        self.init(
            aiAssistRunning: Self.bool(jsonObject["aiAssistRunning"]),
            aiChatRunning: Self.bool(jsonObject["aiChatRunning"]),
            translateRunning: Self.bool(jsonObject["translateRunning"]),
            wordTipsRunning: Self.bool(jsonObject["wordTipsRunning"]),
            paymentRunning: Self.bool(jsonObject["paymentRunning"]),
            cityGuideRunning: Self.bool(jsonObject["cityGuideRunning"]),
            jsaiRunning: Self.bool(jsonObject["jsaiRunning"]),
            accessibilityRunning: Self.bool(jsonObject["accessibilityRunning"]),
            customViewRunning: Self.bool(jsonObject["customViewRunning"]),
            navigationRunning: Self.bool(jsonObject["navigationRunning"]),
            audioRecordRunning: Self.bool(jsonObject["audioRecordRunning"]),
            videoRecordRunning: Self.bool(jsonObject["videoRecordRunning"]),
            phoneCallRunning: Self.bool(jsonObject["phoneCallRunning"]),
            otaRunning: Self.bool(jsonObject["otaRunning"]),
            takePictureRunning: Self.bool(jsonObject["takePictureRunning"]),
            arPictureRunning: Self.bool(jsonObject["arPictureRunning"]),
            mixRecordRunning: Self.bool(jsonObject["mixRecordRunning"]),
            liveBroadcastRunning: Self.bool(jsonObject["liveBroadcastRunning"]),
            musicWordRunning: Self.bool(jsonObject["musicWordRunning"]),
            cameraPageRunning: Self.bool(jsonObject["cameraPageRunning"])
        )
    }

    var hasScenesTakeover: Bool {
        aiChatRunning || translateRunning || wordTipsRunning || paymentRunning ||
        cityGuideRunning || jsaiRunning || accessibilityRunning || navigationRunning ||
        phoneCallRunning || otaRunning || liveBroadcastRunning || cameraPageRunning
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1"
        }
        return false
    }
}

private extension RGCxrServerImpl {
    func handleSceneStatusChanged(_ status: RGCxrServerSceneStatusSnapshot) {
        lastSceneStatus = status
        sendCustomViewRunningIfChanged(status.customViewRunning)

        if status.hasScenesTakeover {
            sendSessionLifecycleIfChanged(state: "unavailable", reason: "scenesTakeover")
        } else if status.aiAssistRunning {
            sendSessionLifecycleIfChanged(state: "paused", reason: "aiStart")
        } else if status.customViewRunning {
            sendSessionLifecycleIfChanged(state: "started", reason: "glassReady")
        } else if lastSessionLifecycleState == "paused" {
            sendSessionLifecycleIfChanged(state: "started", reason: "aiStop")
        }
    }

    func handleScreenResumed() {
        guard let status = lastSceneStatus ?? onGetSceneStatus?() else {
            sendSessionLifecycleIfChanged(state: "available", reason: "other")
            return
        }
        if status.hasScenesTakeover {
            sendSessionLifecycleIfChanged(state: "unavailable", reason: "scenesTakeover")
        } else if status.aiAssistRunning {
            sendSessionLifecycleIfChanged(state: "paused", reason: "aiStart")
        } else if status.customViewRunning {
            sendSessionLifecycleIfChanged(state: "started", reason: "glassReady")
        } else if activeCustomAppPackageName != nil {
            sendSessionLifecycleIfChanged(state: "started", reason: "glassReady")
        } else {
            sendSessionLifecycleIfChanged(state: "available", reason: "other")
        }
    }

    func sendCustomViewRunningIfChanged(_ running: Bool) {
        guard lastCustomViewRunning != running else { return }
        lastCustomViewRunning = running
        if let msg = buildCustomViewRunningStatus(running) {
            sendMessageToClient(msg)
        }
    }

    func sendSessionLifecycleIfChanged(state: String, reason: String?) {
        guard RGCxrSessionManager.shared.activeSession != nil else { return }
        if state == "started" {
            if let screenOn = onGetScreenOn?(), screenOn == false {
                sendSessionLifecycleIfChanged(state: "paused", reason: "screenOffGlass")
                return
            }
            if let status = lastSceneStatus ?? onGetSceneStatus?() {
                if status.hasScenesTakeover {
                    sendSessionLifecycleIfChanged(state: "unavailable", reason: "scenesTakeover")
                    return
                }
                if status.aiAssistRunning {
                    sendSessionLifecycleIfChanged(state: "paused", reason: "aiStart")
                    return
                }
            }
        }

        guard lastSessionLifecycleState != state else { return }
        lastSessionLifecycleState = state
        if let msg = buildSessionLifecycleNotify(state: state, reason: reason) {
            sendMessageToClient(msg)
        }
    }

    func parseScreenOn(_ responseData: Any?) -> Bool? {
        guard let jsonString = responseData as? String,
              let jsonData = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            return nil
        }
        if let value = dict["screen_on"] as? Bool { return value }
        if let value = dict["screen_on"] as? NSNumber { return value.boolValue }
        if let value = dict["screen_on"] as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" || normalized == "1" { return true }
            if normalized == "false" || normalized == "0" { return false }
        }
        return nil
    }
}

/// 构造不同类型的消息
extension RGCxrServerImpl {


    internal func audioForwardingHeartbeat() {
        if let msg = buildPing() {
            sendMessageToClient(msg)
        }
    }

    /// ping 消息
    func buildPing() -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            return [
                "bundleId": bundleId,
                "type": "ping"
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// 通用本地通道启动消息
    /// - Parameters:
    ///   - channelId: 通道标识，例如 audio_down / audio_up / photo 等
    ///   - port: 本地 TCP 端口
    ///   - mode: 传输模式，例如 stream / chunk
    ///   - metadata: 业务自定义元信息（编码格式、声道数、分辨率等）
    func buildLocalChannelStart(channelId: String,
                                port: UInt16,
                                mode: String,
                                metadata: [String: Any]) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            return [
                "bundleId": bundleId,
                "type": "localChannelStart",
                "data": [
                    "channelId": channelId,
                    "port": port,
                    "mode": mode,
                    "metadata": metadata
                ]
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// 通用本地通道关闭消息
    func buildLocalChannelStop(channelId: String) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            return [
                "bundleId": bundleId,
                "type": "localChannelStop",
                "data": [
                    "channelId": channelId
                ]
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// customViewRunning 状态同步消息
    func buildCustomViewRunningStatus(_ running: Bool) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            return [
                "bundleId": bundleId,
                "type": "customViewRunningStatus",
                "data": [
                    "customViewRunning": running
                ]
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// 第三方 App 操作结果消息
    func buildThirdAppResult(type: String, requestId: Int, packageName: String, success: Bool) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            return [
                "bundleId": bundleId,
                "type": type,
                "data": [
                    "requestId": requestId,
                    "packageName": packageName,
                    "success": success
                ]
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// 自定义 View 相关命令（sendIcons / open / update / close）的结果消息
    /// - Parameters:
    ///   - type: 回包消息类型，例如 `openCustomViewResult`
    ///   - errorCode: 仅 `openCustomViewResult` 在失败时可能带有 errorCode
    func buildCustomViewResult(type: String, requestId: Int, success: Bool, errorCode: Int?) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            var data: [String: Any] = [
                "requestId": requestId,
                "success": success
            ]
            if let errorCode {
                data["errorCode"] = errorCode
            }
            return [
                "bundleId": bundleId,
                "type": type,
                "data": data
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// 三方应用 resume 状态变化消息
    func buildAppResumeChange(packageName: String) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            return [
                "bundleId": bundleId,
                "type": "appResumeChange",
                "data": [
                    "packageName": packageName
                ]
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// Session 生命周期状态通知。
    func buildSessionLifecycleNotify(state: String, reason: String?) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            var data: [String: Any] = [
                "state": state
            ]
            if let reason {
                data["reason"] = reason
            }
            return [
                "bundleId": bundleId,
                "type": "sessionLifecycleNotify",
                "data": data
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// installApp 文件上传结果消息
    func buildInstallAppResult(requestId: Int, success: Bool, localPath: String?) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            var data: [String: Any] = [
                "requestId": requestId,
                "success": success
            ]
            if let localPath {
                data["localPath"] = localPath
            }
            return [
                "bundleId": bundleId,
                "type": "installAppResult",
                "data": data
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    /// changeAudioSceneId 结果消息
    func buildChangeAudioSceneIdResult(requestId: Int?, audioSceneId: Int, success: Bool) -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            var data: [String: Any] = [
                "audioSceneId": audioSceneId,
                "success": success
            ]
            if let requestId {
                data["requestId"] = requestId
            }
            return [
                "bundleId": bundleId,
                "type": "changeAudioSceneIdResult",
                "data": data
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    func buildDeviceInfoResult(requestId: Int?, deviceInfo: RGCxrDeviceInfo?) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        var data: [String: Any] = [
            "success": deviceInfo != nil
        ]
        if let requestId {
            data["requestId"] = requestId
        }
        if let deviceInfo {
            data["deviceInfo"] = deviceInfo.dictionary
        }
        return [
            "bundleId": bundleId,
            "type": "deviceInfoResult",
            "data": data
        ].toJsonString()
    }

    func buildDeviceInfoNotify(_ deviceInfo: RGCxrDeviceInfo?) -> String? {
        guard let deviceInfo else { return nil }
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        return [
            "bundleId": bundleId,
            "type": "deviceInfoNotify",
            "data": [
                "deviceInfo": deviceInfo.dictionary
            ]
        ].toJsonString()
    }

    func buildWearingSwitchResult(requestId: Int?, switchOn: Bool) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        var data: [String: Any] = [
            "switchOn": switchOn
        ]
        if let requestId {
            data["requestId"] = requestId
        }
        return [
            "bundleId": bundleId,
            "type": "wearingSwitchResult",
            "data": data
        ].toJsonString()
    }

    func buildDeviceControlResult(type: String,
                                  requestId: Int?,
                                  success: Bool,
                                  levelKey: String?,
                                  level: Int?) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        var data: [String: Any] = [
            "success": success
        ]
        if let requestId {
            data["requestId"] = requestId
        }
        if let level {
            data["level"] = level
            if let levelKey {
                data[levelKey] = level
            }
        }
        return [
            "bundleId": bundleId,
            "type": type,
            "data": data
        ].toJsonString()
    }

    func buildWearingStatusNotify(_ wearing: Bool) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        return [
            "bundleId": bundleId,
            "type": "wearingStatusNotify",
            "data": [
                "wearing": wearing
            ]
        ].toJsonString()
    }

    func buildInterruptAiWakeResult(requestId: Int?, success: Bool) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        var data: [String: Any] = [
            "success": success
        ]
        if let requestId {
            data["requestId"] = requestId
        }
        return [
            "bundleId": bundleId,
            "type": "interruptAiWakeResult",
            "data": data
        ].toJsonString()
    }

    func buildAiWakeInterruptNotify(_ interruptWake: Bool) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        return [
            "bundleId": bundleId,
            "type": "aiWakeInterruptNotify",
            "data": [
                "interruptWake": interruptWake
            ]
        ].toJsonString()
    }

    func buildSendCustomCmdStreamResult(requestId: Int,
                                        success: Bool,
                                        payload: Data?,
                                        errorCode: Int32?,
                                        errorMsg: String?) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        var data: [String: Any] = [
            "requestId": requestId,
            "success": success
        ]
        if let payload {
            data["payload"] = payload.base64EncodedString()
        }
        if let errorCode {
            data["errorCode"] = errorCode
        }
        if let errorMsg {
            data["errorMsg"] = errorMsg
        }
        return [
            "bundleId": bundleId,
            "type": "sendCustomCmdStreamResult",
            "data": data
        ].toJsonString()
    }

    /// pong 消息
    func buildPong() -> String? {
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            return [
                "bundleId": bundleId,
                "type": "pong"
            ].toJsonString()
        } else {
            RGLog.error("no bundleId")
            return nil
        }
    }

    private func parseWearingStatus(_ value: Any?) -> Bool? {
        if let jsonString = value as? String,
           let jsonData = jsonString.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
            if let wearingStatus = jsonObject["wearingStatus"] as? String {
                return wearingStatus == "1"
            }
            return jsonObject["wearingStatus"] as? Bool
        }
        return nil
    }

    private func parseAiWakeInterrupt(_ value: Any?) -> Bool? {
        if let jsonString = value as? String,
           let jsonData = jsonString.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
            if let status = jsonObject["status"] as? Int {
                return status == 1
            }
            return jsonObject["status"] as? Bool
        }
        return nil
    }

    private func encodeNotifyField(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let data = value as? Data {
            return data.base64EncodedString()
        }
        if let str = value as? String {
            // 尝试当作 base64；不是 base64 也无妨，Client 端会兜底按 utf8 string 处理
            return str
        }
        if JSONSerialization.isValidJSONObject(value) {
            return value
        }
        // 其他类型用描述兜底，至少保证 JSON 可编码
        return String(describing: value)
    }

    /// 通用 notify 透传消息
    func buildCxrNotify(_ res: RGCxrDataResponse) -> String? {
        RGLog.info(res.cmd)
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }
        var data: [String: Any] = [
            "cmd": res.cmd,
            "subCmd": res.subCmd,
            "reqId": res.reqId,
            "status": res.status
        ]
        if let payload = encodeNotifyField(res.responseData) {
            data["payload"] = payload
        }
        if let payloadEx = encodeNotifyField(res.responseDataEx) {
            data["payloadEx"] = payloadEx
        }
        return [
            "bundleId": bundleId,
            "type": "cxrNotify",
            "data": data
        ].toJsonString()
    }

    /// sendCustomCmd 结果消息
    /// - Note: payload 若为 Data 会 base64 传输；若无法提取到 payload，则不携带 payload 字段
    func buildSendCustomCmdResult(requestId: Int?, response: RGCxrBaseResponse) -> String? {
        guard let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId else {
            RGLog.error("no bundleId")
            return nil
        }

        var data: [String: Any] = [:]
        if let requestId {
            data["requestId"] = requestId
        }

        if let error = response as? RGCxrErrorResponse {
            data["success"] = false
            data["errorCode"] = error.errorCode
            data["errorMsg"] = error.errorMsg
        } else {
            data["success"] = true
        }

        if let dataResponse = response as? RGCxrDataResponse {
            if let payload = dataResponse.responseData as? Data {
                data["payload"] = payload.base64EncodedString()
            } else if let payload = dataResponse.responseData as? String,
                      let raw = payload.data(using: .utf8) {
                data["payload"] = raw.base64EncodedString()
            }
        }

        return [
            "bundleId": bundleId,
            "type": "sendCustomCmdResult",
            "data": data
        ].toJsonString()
    }
}
