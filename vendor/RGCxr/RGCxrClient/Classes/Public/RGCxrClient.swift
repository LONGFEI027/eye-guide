//
//  RGCxrClient.swift
//  RGCxrClient
//
//  Created by Ginger on 2026/2/28.
//

import Foundation
import Combine
import RGCoreKit

/// 集成方选择的 CXR 客户端运行形态（用于初始化与后续扩展；当前实现主要约束使用顺序与事件门禁）。
public enum RGCxrClientInitMode: Sendable {
    /// 以自定义 View 方式接入
    case customView
    /// 以自定义 App（眼镜端三方应用）方式接入
    case customApp
}

/// `CxrClient.initialize` 的附加参数。宿主 `bundleId`（GATT / 鉴权）始终使用 `Bundle.main.bundleIdentifier`（与老逻辑一致），不在此传入。
public struct RGCxrClientInitializationOptions: Sendable {
    /// 发起鉴权时可选的应用展示名。
    public var appDisplayName: String?
    /// 眼镜端三方应用包名；`queryApp` / `openApp` / `stopApp` / `uninstallApp` 内部使用该值作为 `packageName`。
    public var pageName: String?

    public init(appDisplayName: String? = nil, pageName: String? = nil) {
        self.appDisplayName = appDisplayName
        self.pageName = pageName
    }
}

/// `CxrClient.initialize` 的返回结果。
public enum RGCxrClientInitializeOutcome: Sendable {
    case success
    /// 当前进程中已成功初始化过，本次调用被忽略。
    case failureAlreadyInitialized
}

public enum RGCxrAudioSceneId: Int, Sendable {
    /// 近场
    case interaction = 0
    /// 远场
    case translation = 1
    /// 全场
    case call = 2
    /// 暂时不用
    case conference = 3
}

/// 音频开始事件信息
public struct RGCxrClientAudioStartEvent {
    public let codec: Int32
    public let type: String
    public let channels: UInt32

    public init(codec: Int32, type: String, channels: UInt32) {
        self.codec = codec
        self.type = type
        self.channels = channels
    }
}

/// 音频数据流事件信息
public struct RGCxrClientAudioDataEvent {
    public let data: Data
    public let timestamp: UInt64

    public init(data: Data, timestamp: UInt64) {
        self.data = data
        self.timestamp = timestamp
    }
}

/// 音频事件
public enum RGCxrClientAudioEvent {
    /// 音频开始
    case started(RGCxrClientAudioStartEvent)
    /// 音频数据流
    case stream(RGCxrClientAudioDataEvent)
}

/// 自定义 View 运行状态事件
public struct RGCxrClientCustomViewRunningEvent {
    public let isRunning: Bool

    public init(isRunning: Bool) {
        self.isRunning = isRunning
    }
}

/// 眼镜端三方应用 resume 状态变化事件
public struct RGCxrClientAppResumeChangeEvent {
    public let packageName: String

    public init(packageName: String) {
        self.packageName = packageName
    }
}

/// 眼镜侧 notify 透传事件（Server 将 `RGCxrKit.dataNotifyPublisher` 的通知组装后回传给 Client）。
public struct RGCxrClientNotifyEvent {
    public let cmd: String
    public let subCmd: String
    public let reqId: Int32
    public let status: Int32
    public let payload: Data?
    public let payloadEx: Data?

    public init(cmd: String,
                subCmd: String,
                reqId: Int32,
                status: Int32,
                payload: Data?,
                payloadEx: Data?) {
        self.cmd = cmd
        self.subCmd = subCmd
        self.reqId = reqId
        self.status = status
        self.payload = payload
        self.payloadEx = payloadEx
    }
}

/// `RGCxrClient` 公共方法的前置条件检查错误。
/// 仅覆盖同步可判定、必须阻断调用继续执行的情况；业务/异步结果仍通过各方法的 `callback` 返回。
/// 所有公共可变方法的返回值为 `RGCxrClientError?`：`nil` 表示前置条件通过、已进入异步流程；
/// 非 `nil` 表示因该错误码对应的原因被拒绝执行，此时**不会**触发 `callback`。
public enum RGCxrClientError: Int, Error, Sendable {
    /// SDK 未初始化（未成功调用过 `CxrClient.initialize`）。
    case notInitialized        = 1001
    /// 当前 `RGCxrClientInitMode` 与该方法要求的模式不匹配。
    case modeMismatch          = 1002
    /// 未鉴权或 token 已过期。
    case notAuthenticated      = 1003
    /// 已鉴权但缺少该方法所需的 `RGCxrClientAuthPermission`。
    case permissionDenied      = 1004
    /// 运行时前置状态不满足：
    /// - `customView` 模式下 `openCustomView` 未成功或自定义 View 尚未运行；
    /// - `customApp` 模式下 `openApp` 未成功或目标应用未 resume。
    case notReady              = 1005
    /// Session 已暂停，需等待恢复到 Started 后再调用。
    case sessionPaused         = 1006
    /// Session 已不可用，需重新创建或重新打开眼镜端会话终端。
    case sessionUnavailable    = 1007
    /// Session 已销毁。
    case sessionDestroyed      = 1008
}

public protocol RGCxrClient: AnyObject {
    var auth: RGCxrClientAuthManager { get }

    /// 音频事件流（音频开始、音频数据流）
    /// 鉴权必须通过RGCxrClientAuthPermission.microphone才能使用
    var audioEventPublisher: AnyPublisher<RGCxrClientAudioEvent, Never> { get }

    /// 自定义 View 运行状态事件流
    var customViewRunningEventPublisher: AnyPublisher<RGCxrClientCustomViewRunningEvent, Never> { get }

    /// 眼镜端三方应用 resume 状态变化事件流
    var appResumeChangeEventPublisher: AnyPublisher<RGCxrClientAppResumeChangeEvent, Never> { get }

    /// 眼镜侧 notify 透传事件流（例如业务自定义通知）
    /// 仅在RGCxrClientInitMode为customApp时可订阅/使用
    var notifyEventPublisher: AnyPublisher<RGCxrClientNotifyEvent, Never> { get }

    /// 设备信息通知事件流。
    var deviceInfoEventPublisher: AnyPublisher<RGCxrDeviceInfo, Never> { get }

    /// 佩戴状态通知事件流，true 表示已佩戴。
    var wearingStatusEventPublisher: AnyPublisher<Bool, Never> { get }

    /// AI 唤醒拦截状态通知事件流，true 表示眼镜不响应语音唤醒 AI 助手。
    var aiWakeInterruptEventPublisher: AnyPublisher<Bool, Never> { get }

    /// 设置可监听的 notify 事件 key（对应 `RGCxrClientNotifyEvent.cmd`）。
    /// 默认不设置时不会收到任何 notify 事件；仅当 `cmd` 在白名单中时才会通过 `notifyEventPublisher` 透出。
    /// 仅在RGCxrClientInitMode为customApp时可调用
    /// - Parameter cmds: 允许透出的 `cmd` 列表；传空将清空白名单（不再接收任何 notify）
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`；`nil` 表示已执行。
    @discardableResult
    func setNotifyEventListenCmds(_ cmds: [String]) -> RGCxrClientError?

    func handleOpenURL(_ url: URL) -> Bool

    /// 发送 icons 给眼镜
    /// 仅在RGCxrClientInitMode为customView时可调用
    /// - Parameters:
    ///   - icons: 自定义 View 图标数据参数，[{"data":"xxx","name":"icon_name0"},{"data":"xxx","name":"icon_name1"}]
    ///   - callback: 眼镜回包结果；大文本经本地 TCP 上传，约 30 秒内未完成（含 TCP 与眼镜回包）视为失败（`false`）
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func sendCustomViewIcons(_ icons: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 发送自定义指令给眼镜端（由业务自定义解析）。
    /// 仅在RGCxrClientInitMode为customApp且openApp成功后可调用
    /// - Parameters:
    ///   - cmd: 自定义命令名
    ///   - payload: 可选二进制载荷（将以 base64 编码传输）
    ///   - callback: 眼镜回包结果；`success=false` 时可能携带 `errorCode/errorMsg`；若 `payload` 存在将以 base64 解码回传
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func sendCustomCmd(cmd: String,
                       payload: Data?,
                       callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError?

    /// - Returns: 同 `sendCustomCmd(cmd:payload:callback:)`。
    @discardableResult
    func sendCustomCmd(cmd: String, payload: Data?) -> RGCxrClientError?

    /// 发送自定义指令和大二进制数据给眼镜端。小参数走 BLE，stream 数据走本地 TCP。
    /// 仅在RGCxrClientInitMode为customApp且openApp成功后可调用
    @discardableResult
    func sendCustomCmdStream(cmd: String,
                             payload: Data?,
                             stream: Data,
                             callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError?

    /// 获取当前眼镜设备信息。
    @discardableResult
    func getDeviceInfo(callback: ((RGCxrDeviceInfo?) -> Void)?) -> RGCxrClientError?

    /// 获取佩戴检测开关，true 表示开。
    @discardableResult
    func getWearingSwitch(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 设置眼镜亮度，level 范围为 0...15。
    @discardableResult
    func setBrightness(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 查询眼镜亮度。
    @discardableResult
    func getBrightness(callback: ((Int?) -> Void)?) -> RGCxrClientError?

    /// 设置眼镜音量，level 范围为 0...15。
    @discardableResult
    func setVolume(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 查询眼镜音量。
    @discardableResult
    func getVolume(callback: ((Int?) -> Void)?) -> RGCxrClientError?

    /// 设置是否拦截 AI 语音唤醒，true 表示拦截。
    @discardableResult
    func interruptAiWake(_ interruptWake: Bool, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 通知眼镜打开自定义 View
    /// 仅在RGCxrClientInitMode为customView时可调用
    /// - Parameters:
    ///   - view: 自定义 View 描述（大文本经本地 TCP 上传）
    ///   - callback: 眼镜回包结果；`success=false` 时 `errorCode` 可能为 `-1`（OTA/Phone 进行中）；
    ///              TCP 失败或约 30 秒内未收到眼镜反馈视为失败，此时 `errorCode` 为 `nil`
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func openCustomView(_ view: String, callback: ((_ success: Bool, _ errorCode: Int?) -> Void)?) -> RGCxrClientError?

    /// 通知眼镜更新自定义 View
    /// 仅在RGCxrClientInitMode为customView并且openCustomView成功后（是否成功参考customViewRunningEventPublisher）可调用
    /// - Parameters:
    ///   - view: 自定义 View 描述（大文本经本地 TCP 上传）
    ///   - callback: 眼镜回包结果；约 30 秒内未完成（含 TCP 与眼镜回包）视为失败（`false`）
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func updateCustomView(_ view: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 通知眼镜关闭自定义View
    /// 仅在RGCxrClientInitMode为customView并且openCustomView成功后（是否成功参考customViewRunningEventPublisher）可调用
    /// - Parameters:
    ///   - callback: 眼镜回包结果；1 秒内未收到眼镜反馈视为失败（`false`）
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func closeCustomView(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 开启眼镜音频采集
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// 鉴权必须通过RGCxrClientAuthPermission.microphone才能使用
    /// - Parameters:
    ///   - type: 自定义类型
    ///   - codec: 编码格式
    ///   - mode: 音频类型
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`；`nil` 表示已下发。
    @discardableResult
    func startRecord(_ type: String, codec: RGCxrAudioCodec, mode: RGCxrAudioMode) -> RGCxrClientError?

    /// 关闭眼镜音频采集
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// 鉴权必须通过RGCxrClientAuthPermission.microphone才能使用
    /// - Parameter type: 自定义类型
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`；`nil` 表示已下发。
    @discardableResult
    func stopRecord(_ type: String) -> RGCxrClientError?

    /// 开始播放音频
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// - Parameter codec: 音频格式
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`；`nil` 表示已下发。
    @discardableResult
    func startPlayAudio(codec: RGCxrAudioCodec) -> RGCxrClientError?

    /// 停止播放音频
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`；`nil` 表示已下发。
    @discardableResult
    func stopPlayAudio() -> RGCxrClientError?

    /// 播放音频
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// - Parameter data: 音频数据
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`；`nil` 表示已下发。
    @discardableResult
    func feedAudio(_ data: Data) -> RGCxrClientError?

    /// 拍照，拍照结果存到相册
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// 鉴权必须通过RGCxrClientAuthPermission.camera才能使用
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`；`nil` 表示已下发。
    @discardableResult
    func takePhoto() -> RGCxrClientError?

    /// 拍照，拍照结果通过数据流返回
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// 鉴权必须通过RGCxrClientAuthPermission.camera才能使用
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func takePhotoWithData(width: Int, height: Int, quality: Int, callback: ((Data) -> Void)?) -> RGCxrClientError?

    /// 查询眼镜是否已安装由 `RGCxrClientInitializationOptions.pageName` 指定的应用。
    /// 仅在RGCxrClientInitMode为customApp时可调用
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func queryApp(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 打开第三方 app；`packageName` 取自初始化时的 `RGCxrClientInitializationOptions.pageName`。
    /// 优先检查 `url` 使用 deeplink 打开，若 `url` 为空则使用包名加 `activityName` 打开。
    /// 仅在RGCxrClientInitMode为customApp时可调用
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func openApp(activityName: String, url: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 停止眼镜上的三方应用；包名取自 `RGCxrClientInitializationOptions.pageName`。
    /// 仅在RGCxrClientInitMode为customApp且openApp成功后可调用
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func stopApp(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 卸载眼镜上的三方应用；包名取自 `RGCxrClientInitializationOptions.pageName`。
    /// 仅在RGCxrClientInitMode为customApp时可调用
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func uninstallApp(callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 眼镜安装第三方应用
    /// 仅在RGCxrClientInitMode为customApp时可调用
    /// - Parameters:
    ///   - path: 应用本地路径
    ///   - callback: 安装成功失败
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func installApp(_ path: String, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// 切换眼镜录音声场模式（拾音模式）
    /// 两种ClientMode都可以用，但是要确保openCustomView成功或者openApp成功（appResumeChangeEventPublisher中的pageName为RGCxrClientInitializationOptions.pageName）
    /// - Parameters:
    ///   - audioSceneId: 模式 ID（由眼镜端定义）
    ///   - callback: 眼镜端执行成功失败
    /// - Returns: 前置条件不满足时返回对应 `RGCxrClientError`，此时 `callback` 不会被触发；`nil` 表示已进入异步流程。
    @discardableResult
    func changeAudioSceneId(_ audioSceneId: RGCxrAudioSceneId, callback: ((Bool) -> Void)?) -> RGCxrClientError?

    /// Rokid App是否已经安装
    func isRokidAppInstalled() -> Bool
}

public final class CxrClient {
    public static var shared: RGCxrClient = RGCxrClientImpl()

    /// 当前进程是否已完成 SDK 初始化（`CxrClient.initialize` 成功调用过）。
    public static var isInitialized: Bool {
        RGCxrClientLifecycle.isInitialized
    }

    /// 首次成功初始化时选择的模式；未完成初始化时为 `nil`。
    public static var initializationMode: RGCxrClientInitMode? {
        RGCxrClientLifecycle.snapshot?.mode
    }

    /// 在 App 生命周期内尽早调用，且**每个进程最多成功执行一次**。
    /// 未完成初始化前，不得使用 `RGCxrClient` / `RGCxrClientAuthManager` 的对外能力，也不会收到业务与鉴权事件流。
    @discardableResult
    public static func initialize(mode: RGCxrClientInitMode, options: RGCxrClientInitializationOptions) -> RGCxrClientInitializeOutcome {
        let first = RGCxrClientLifecycle.performFirstInitialize(mode: mode, options: options) {
            (shared as? RGCxrClientImpl)?.applyInitialization(mode: mode, options: options)
        }
        if !first {
            RGLog.error("[CxrClient] initialize 每个进程仅允许成功调用一次")
        }
        return first ? .success : .failureAlreadyInitialized
    }

    /// 创建 CXR-L iOS 新接口总入口；现有 `RGCxrClient` API 保持不变。
    public static func makeLink(appDisplayName: String? = nil) -> RGCxrLink {
        RGCxrLinkImpl(
            appDisplayName: appDisplayName,
            client: shared
        )
    }

    /// 创建 Android CXR-L SDK 对齐的独立 session；建议新代码优先使用 `makeLink(appDisplayName:)`。
    public static func makeSession(_ config: RGCxrSessionConfig) -> RGCxrSession {
        let link = RGCxrLinkImpl(appDisplayName: config.appDisplayName, client: shared)
        switch config.type {
        case .customView:
            return link.makeCustomViewSession()
        case .customApp:
            return link.makeCustomAppSession(packageName: config.customAppPackageName ?? "")
        }
    }

    private init() {}
}
