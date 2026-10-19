//
//  RGCxrSession.swift
//  RGCxrClient
//
//  Created by Codex on 2026/6/6.
//

import Foundation
import Combine
import RGCoreKit

/// Android CXR-L SDK 对齐的会话类型。
public enum RGCxrSessionType: Sendable {
    /// 以自定义 View 方式接入。
    case customView
    /// 以自定义 App（眼镜端三方应用）方式接入。
    case customApp
}

/// Session AI 唤醒处理策略。
public enum RGCxrAiInterceptMode: Sendable {
    /// 允许系统 AI 唤起，Session 临时进入 Paused，AI 结束后回到 Available，由调用方重新 open/start。
    case allowWithPause
    /// 尝试拦截系统 AI，让当前 Session 独占。
    case blockAI
}

/// Session 业务通信状态。
public enum RGCxrSessionState: String, Sendable {
    /// 双端终端或基础链路已准备，但还未进入业务可调用态。
    case available
    /// 业务可正常通信。
    case started
    /// Session 保留但暂时不可发起新业务。
    case paused
    /// 眼镜端终端退出或被其他 CXR 场景接管。
    case unavailable
}

/// Session 状态迁移原因。
public enum RGCxrSessionStateReason: String, Sendable {
    case glassReady
    case linkConnected
    case linkDisconnected
    case screenOffGlass
    case aiStart
    case aiStop
    case glassIdle
    case scenesTakeover
    case other
}

/// Session 状态事件。
public struct RGCxrSessionStateEvent: Sendable {
    public let state: RGCxrSessionState
    public let reason: RGCxrSessionStateReason?

    public init(state: RGCxrSessionState, reason: RGCxrSessionStateReason?) {
        self.state = state
        self.reason = reason
    }
}

/// Android CXR-L SDK 对齐的会话配置。
public struct RGCxrSessionConfig: Sendable {
    /// 会话类型。
    public var type: RGCxrSessionType
    /// 眼镜端三方应用包名；仅 `customApp` 会话需要。
    public var customAppPackageName: String?
    /// 发起 iOS scheme 鉴权时展示的应用名。
    public var appDisplayName: String?
    /// AI 唤醒处理策略。
    public var aiInterceptMode: RGCxrAiInterceptMode

    public init(type: RGCxrSessionType,
                customAppPackageName: String? = nil,
                appDisplayName: String? = nil,
                aiInterceptMode: RGCxrAiInterceptMode = .allowWithPause) {
        self.type = type
        self.customAppPackageName = customAppPackageName
        self.appDisplayName = appDisplayName
        self.aiInterceptMode = aiInterceptMode
    }
}

/// 拍照/图像流事件。
public enum RGCxrSessionImageEvent {
    /// 收到图片数据。
    case received(Data)
    /// 图片流错误。
    case error(code: Int, message: String?)
}

/// 自定义 View 生命周期事件。
public enum RGCxrSessionCustomViewEvent {
    case opened
    case updated
    case closed
    case iconsSent
    case error(code: Int, message: String?)
}

/// 眼镜 AI 助手事件。
public enum RGCxrSessionAiAssistEvent {
    case started
    case stopped
}

/// CXR-L iOS 新接口的总入口。
///
/// `RGCxrLink` 负责 session 之前的动作：初始化、scheme 鉴权、URL 回调处理、BLE 通道状态监听以及创建 typed session。
public protocol RGCxrLink: AnyObject {
    var events: RGCxrLinkEvents { get }

    func authenticate(scopes: [RGCxrClientAuthPermission],
                      completion: ((Result<(token: String, sessionId: String?), Error>) -> Void)?)

    func handleOpenURL(_ url: URL) -> Bool

    func disconnect()

    func makeCustomViewSession(aiInterceptMode: RGCxrAiInterceptMode) -> RGCxrCustomViewSession

    func makeCustomAppSession(packageName: String, aiInterceptMode: RGCxrAiInterceptMode) -> RGCxrCustomAppSession
}

public extension RGCxrLink {
    func makeCustomViewSession() -> RGCxrCustomViewSession {
        makeCustomViewSession(aiInterceptMode: .allowWithPause)
    }

    func makeCustomAppSession(packageName: String) -> RGCxrCustomAppSession {
        makeCustomAppSession(packageName: packageName, aiInterceptMode: .allowWithPause)
    }
}

/// Link 入口级事件：鉴权与 BLE 通道状态。
public protocol RGCxrLinkEvents: AnyObject {
    var authStatePublisher: AnyPublisher<RGCxrClientAuthState, Never> { get }
    var authEventPublisher: AnyPublisher<RGCxrClientAuthEvent, Never> { get }
    var connectionStatePublisher: AnyPublisher<Bool, Never> { get }
}

/// CustomView / CustomApp session 共享的基础能力。
public protocol RGCxrSession: AnyObject {
    var config: RGCxrSessionConfig { get }
    var state: RGCxrSessionState { get }
    var statePublisher: AnyPublisher<RGCxrSessionStateEvent, Never> { get }
    var destroyedPublisher: AnyPublisher<Void, Never> { get }
    var device: RGCxrSessionDevice { get }
    var media: RGCxrSessionMedia { get }
    var ai: RGCxrSessionAI { get }
    var deviceEvents: RGCxrSessionDeviceEvents { get }
    var mediaEvents: RGCxrSessionMediaEvents { get }
    var aiEvents: RGCxrSessionAIEvents { get }

    @discardableResult
    func destroy(callback: ((Bool) -> Void)?) -> RGCxrClientError?
}

/// CustomView 专属 session。
public protocol RGCxrCustomViewSession: RGCxrSession {
    var customView: RGCxrSessionCustomView { get }
    var customViewEvents: RGCxrCustomViewEvents { get }
}

/// CustomApp 专属 session。
public protocol RGCxrCustomAppSession: RGCxrSession {
    var app: RGCxrSessionApp { get }
    var commands: RGCxrSessionCommands { get }
    var appEvents: RGCxrCustomAppEvents { get }
    var commandEvents: RGCxrCommandEvents { get }
}

public protocol RGCxrSessionDevice: AnyObject {
    @discardableResult
    func getGlassDeviceInfo(callback: ((RGCxrDeviceInfo?) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func isWearingCheckOn(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func setBrightness(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func getBrightness(callback: ((Int?) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func setVolume(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func getVolume(callback: ((Int?) -> Void)?) -> RGCxrClientError?
}

public protocol RGCxrSessionMedia: AnyObject {
    @discardableResult
    func startAudioStream(codec: RGCxrAudioCodec, mode: RGCxrAudioMode) -> RGCxrClientError?

    @discardableResult
    func stopAudioStream() -> RGCxrClientError?

    @discardableResult
    func startPlayAudio(codec: RGCxrAudioCodec) -> RGCxrClientError?

    @discardableResult
    func stopPlayAudio() -> RGCxrClientError?

    @discardableResult
    func feedAudio(_ data: Data) -> RGCxrClientError?

    @discardableResult
    func takePhoto() -> RGCxrClientError?

    @discardableResult
    func takePhoto(width: Int, height: Int, quality: Int, callback: ((Data) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func changeAudioSceneId(_ audioSceneId: RGCxrAudioSceneId, callback: ((Bool) -> Void)?) -> RGCxrClientError?
}

public protocol RGCxrSessionAI: AnyObject {
    @discardableResult
    func sendExitAI(playSound: Bool, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func setInterruptAiWake(_ interruptWake: Bool, callback: ((Bool) -> Void)?) -> RGCxrClientError?
}

public protocol RGCxrSessionCustomView: AnyObject {
    @discardableResult
    func setIcons(_ iconData: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func open(_ viewData: String,
              callback: ((_ success: Bool, _ errorCode: Int?) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func update(_ viewData: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func close(callback: ((Bool) -> Void)?) -> RGCxrClientError?
}

public protocol RGCxrSessionApp: AnyObject {
    @discardableResult
    func uploadAndInstall(path: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func uninstall(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func start(activityName: String,
               interruptAiWake: Bool,
               callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func start(activityName: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func stop(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func isInstalled(callback: ((Bool) -> Void)?) -> RGCxrClientError?
}

public protocol RGCxrSessionCommands: AnyObject {
    @discardableResult
    func setNotifyEventListenCmds(_ cmds: [String]) -> RGCxrClientError?

    @discardableResult
    func send(cmd: String,
              payload: Data?,
              callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError?

    @discardableResult
    func send(cmd: String,
              payload: Data?,
              stream: Data,
              callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError?
}

public protocol RGCxrSessionDeviceEvents: AnyObject {
    var deviceInfoPublisher: AnyPublisher<RGCxrDeviceInfo, Never> { get }
    var wearingStatusPublisher: AnyPublisher<Bool, Never> { get }
}

public protocol RGCxrSessionMediaEvents: AnyObject {
    var audioPublisher: AnyPublisher<RGCxrClientAudioEvent, Never> { get }
    var imagePublisher: AnyPublisher<RGCxrSessionImageEvent, Never> { get }
}

public protocol RGCxrSessionAIEvents: AnyObject {
    var aiAssistPublisher: AnyPublisher<RGCxrSessionAiAssistEvent, Never> { get }
    var aiWakeInterruptPublisher: AnyPublisher<Bool, Never> { get }
}

public protocol RGCxrCustomViewEvents: AnyObject {
    var lifecyclePublisher: AnyPublisher<RGCxrSessionCustomViewEvent, Never> { get }
}

public protocol RGCxrCustomAppEvents: AnyObject {
    var resumePublisher: AnyPublisher<Bool, Never> { get }
}

public protocol RGCxrCommandEvents: AnyObject {
    var notifyPublisher: AnyPublisher<RGCxrClientNotifyEvent, Never> { get }
}
