//
//  RGCxrProtocol.swift
//  RGCxrCore
//
//  Created by Ginger on 2026/1/13.
//

import Foundation

public enum RGCxrSubCmd: String {
    // DEV
    case Dev_GetGlassInfo   // 获取设备信息
    case Dev_BatteryChanged // 眼镜电量更新通知
    case Dev_TimeUpdate     // 同步手机时间、时区
    case Dev_GlassSound    // 设置声音
    case Dev_GlassBrightness    // 设置亮度
    case Dev_WearingStatus // 眼镜佩戴情况
    case Dev_Operate  // 新手引导同步手机按键情况
    case Dev_LegStatus  // 同步手机眼镜腿情况 ("0"折叠)
    case Dev_GlassesShutdown // 眼镜关机消息
    case Dev_Screen_Status // 同步眼镜屏幕状态，{"screen_on":true}，true:亮屏，false:熄屏

    // MED
    case Sync_Start       // 开始同步
    case Sync_Stop        // 同步结束
    case UnSync_Count     // 请求未同步媒体文件数量
    case Med_Count_Update // 眼镜媒体文件更新
    case Med_NotifyArPictureResult // 眼镜AR截屏结果
    case Med_Take_Photo_Global // 眼镜拍照，拍照完成后将数据发送到手机
    case Med_NotifyMixRecordResult // 眼镜AR录屏结果
    case Med_StartLogZip // 手机通知眼镜开始日志压缩
    case Med_LogZip_Status // 眼镜通知手机日志压缩状态
    case Med_Take_Photo_Url // 拍照并获取图片路径


    // AI
    case KeyDown             // 开始长按
    case KeyUp               // 结束长按
    case Exit                // 退出应用
    case NoNetwork           // 没有联网提示
    case ASR_Result          // Asr识别结果
    case ASR_Error           // Asr识别错误
    case ASR_None            // Asr识别结果最终为空
    case Ai_Error            // Ai请求失败
    case Ai_OpenCamera       // 请求打开相机 识别10个字判断看一看
    case Ai_TakePhoto        // 请求眼镜拍照
    case TTS_Result          // TTS内容返回
    case TTS_AudioFinished   // TTS音频播放结束
    case Pic_UploadError     // 图片上传oss失败
    case Ai_OnLineInstruct   // 在线语音指令
    case Ai_SceneStatus      // 眼镜场景状态上报
    case ASR_End // VAD end
    case Ai_Heartbeat // 心跳
    case Ai_EnterSubAgent // 触发子智能体
    case Both_KeyDown // 双指长按
    case KeyDown_Client // 手机端向眼镜端发送启动ai助手，眼镜端需要传回启动ai助手事件
    case Ai_RenderPayload // 手机端向眼镜端发送发jsUI
    case Ai_PhoneInterrupt // 连续对话打断
    case Ai_Interrupt_Wake // 拦截 AI 语音唤醒
    case Ai_Waked // 眼镜通知手机 AI 唤醒拦截状态
    case Ai_Tool_Status // 工具调用状态
    case Ai_JSUI_ASR // JSUI使用语音返回ASR信息
    case Ai_JSUI_ASR_STOP // JSUI停止调用Asr识别
    case Ai_JSUI_Error // JSUI调用asr失败
    case Audio_Finish_Wake // 连续对话进入下一轮

    // RTC
    case OnStart             // 发起 AI 实时对话
    case OnStop              // 结束AI对话
    case NotifyConfig        // 图片分辨率、帧率
    case OnPushVideoFrame    // 发送视频帧
    case NotifyUserSpeaking  // 用户说话状态
    case NotifyUserAsr       // ASR 识别文本
    case NotifyAIResponse    // 智能体回应文本
    case NotifyCallBegin     // RTC通话开始

    // Sys
    case WordTips_PageContentLanguage // 眼镜通知手机端当前演讲内容的语言种类识别
    case Weather_SendData // 发送天气信息
    case Weather_Send8HourData // 发送天气信息
    case Weather_GetData // 眼镜主动获取天气信息
    case Weather_Get8HourData // 眼镜主动获取天气信息
    case Rec_GetName   // 眼镜从手机获取地理位置信息
    case WordTips_AiContent // 手机将提词器asr发给眼镜
    case WordTips_SendData // 手机发送提词器txt文本内容给眼镜
    case WordTips_SetTvConfig // 手机设置文本信息给眼镜
    case WordTips_SetBTDevice // 发送蓝牙外设给眼镜
    case WordTips_AllDevices // 眼镜主动发送所有连接过的外设信息
    case WordTips_StartBTScan // 通知眼镜开启搜索蓝牙设备
    case WordTips_StopBTScan // 通知眼镜关闭搜索蓝牙设备
    case Sys_StartGetWifiList // 开始获取wifi列表
    case Sys_StopGetWifiList // 停止获取wifi列表
    case Sys_UpdateWifiList // 眼镜向手机发送wifi列表
    case Msg_SendGlobalToast // 系统Toast：显示系统 Toast通知
    case Sys_Reconnect // 服务异常重新连接socket服务
    case Sys_RestoreFactory // 手机发送信息通知眼镜恢复出厂设置
    case Scene_Control // 手机向眼镜发送场景控制指令
    case Sys_Shutdown // 手机向眼镜发送关机指令
    case Sys_Reboot // 手机向眼镜发送重启指令
    case WordTips_SetMatchConfig // 手机设置智能匹配配置给眼镜
    case Sys_SyncAncsApps // 通知App同步
    case Sys_App_Open     // 打开眼镜上的三方应用
    case Sys_App_Stop // 停止眼镜上的三方应用
    case Sys_App_Query // 查询眼镜上的三方应用
    case Sys_App_Open_Succeed // 打开眼镜上的三方应用成功
    case Sys_App_Open_Failed // 打开眼镜上的三方应用失败
    case Sys_App_Stop_Succeed // 关闭眼镜上的三方应用失败
    case Sys_App_Stop_Failed // 关闭眼镜上的三方应用失败
    case Sys_Apk_Uninstall // 卸载眼镜app
    case Sys_Apk_Uninstall_Succeed // 眼镜app卸载成功
    case Sys_Apk_Uninstall_Failed // 眼镜app卸载失败
    case Sys_Apk_Install_Succeed // 眼镜app安装成功
    case Sys_Apk_Install_Failed // 眼镜app安装失败
    case Sys_App_Resume_Change // 眼镜中的应用resume状态发生变化
    case Tts_SendPlayTts // 眼镜端让手机播放tts内容
    case WordTips_RemoveBTDevice // 手机将想要删除的已配对蓝牙设备
    case Schedule_Dismiss // 眼镜通知手机日程提示UI消失
    case Sys_fetchContacts // 眼镜端发送获取通讯录信息给手机
    case Sys_sendContacts // 手机发送通讯录信息给眼镜
    case Sys_Contacts_Enable // 手机发送打电话的信息给眼镜
    case Sys_Contacts_Select // 手机发送选择联系人，第几个给眼镜
    case Sys_Contacts_Page // 手机发送选择联系人，翻页/第几页 给眼镜
    case Sys_Contacts_NotMatch // 手机发送 电话场景没有触发相关本地意图 给眼镜
    case Sys_Contacts_Start // 眼镜端通知手机进入电话智能体
    case Sys_Contacts_Stop // 眼镜发送退出电话号码选择页面
    case Sys_sendSingleContact // 手机发送打电话的信息给眼镜
    case Sys_sendEventData // 眼镜发送埋点信息(眼镜 -> 手机)
    case Sys_Bt_Gatt_Server // 开启CXR-L BLE服务
    case Sys_Bt_Gatt_Msg // CXR-L消息
    case Msg_SendGlobalLocalTtsMsg // 眼镜系统本地TTS播报
    case Sys_Bluetooth_Pair // A2DP流转
    case Sys_Bluetooth_Discoverable // A2DP流转
    case Sys_ChangeAudioSceneId // 切换眼镜录音声场模式（手机->眼镜）
    case Sys_Msg_Tts_Stop // 眼镜通知手机停止播报
    case Sys_Msg_Tts_Stopped // 手机通知眼镜播报已停止
    case Sys_Cloud_Server_Status // 手机通知眼镜手机 websocket 服务状态，{"status": 0}，int 服务状态(0正常， 1 弱网， 2 断网)
    case Scene_GetSceneStatusInfo // 手机向眼镜获取某个场景的状态信息
    case Scene_NotifySceneStatusInfo // 眼镜向手机发送某个场景的状态信息
    case Scene_NotifySceneOpenFailed // 手机通过指令打开眼镜端某些场景，因其他场景运行状况等因素，有打开失败的情况，需要通知给手机端
    case Scene_Recovery   //眼镜端发送场景恢复指令到眼镜端

    // Trans
    case Trans_Ready // 翻译准备就绪
    case Trans_Start // 开始翻译
    case Trans_Stop // 结束翻译
    case Trans_Result // 翻译结果
    case Trans_SetTvConfig // 翻译设置
    case Trans_RequestChangeSceneId // 手机设置眼镜录音模式
    case Trans_Language_info // 翻译语言
    case Trans_ControlServerState // 眼镜端展示或隐藏翻译服务状态

    // Ota
    case Ota_NormalStart // 手机完成版本检测、包大小检测、wifi 配网、 ota条件检测后，通知眼镜进行ota
    case Ota_MsgNotify // 眼镜进行ota，整个过程会不断向手机端上报进度消息
    case Ota_CheckStatus // 手机端查询当前OTA状态
    case Ota_SetAutoOtaConfig // 手机端设置自动OTA配置，用于 眼镜自动 OTA
    case Ota_QueryDeviceStatus  // 机端查询设备状态 内存是否够用
    case Ota_ResultDeviceStatus // 眼镜端回复手机端设备状态查询
    case Ota_NormalStop // 主动关闭当前 OTA 流程

    // Nav
    case Nav_Start // 手机向眼镜发送开始导航消息
    case Nav_Stop // 手机向眼镜发送结束导航消息
    case Nav_UpdateInfo // 手机向眼镜同步导航信息
    case Nav_UpdateLocPermissionTip // 更新眼镜端无后台权限提示
    case Nav_NetProxyRequest // 眼镜向手机发起网络请求
    case Nav_NetProxyResponse // 手机将请求结果发送眼镜
    case Nav_Data // 手机将高德Agent 数据 发送眼镜
    case Nav_SetShowMode // 手机向眼镜同步地图模式
    case Nav_Map_Data //

    case Settings_Update // 手机向眼镜同步 设置信息

    // Schedule
    case Schedule_Add // 手机将新建日程发送给眼镜
    case Schedule_Remove // 删除日程
    case Schedule_Sync // 同步所有日程

    // Memo
    case Memo_Sync // 同步备忘

    // Custom_View
    case Send_Custom_View_Icons // 手机发送Icons给眼镜
    case Custom_View_Icons_Sent // 眼镜通知手机Icons已发送
    case Open_Custom_View // 手机通知眼镜打开自定义View
    case Custom_View_Opened // 眼镜通知手机自定义View已打开
    case Custom_View_Open_Failed // 眼镜通知手机自定义View打开失败
    case Update_Custom_View // 手机通知眼镜更新自定义View
    case Custom_View_Updated // 眼镜通知手机自定义View已更新
    case Close_Custom_View // 手机通知眼镜关闭自定义View
    case Custom_View_Closed // 眼镜通知手机自定义View已关闭

    // Pay
    case Pay_InitAllSdk
    case Pay_StartRecording
    case Pay_StopRecording
    case Pay_NetProxyRequest
    case Pay_NetProxyResponse
    case Pay_DeviceProxyRequest
    case Pay_DeviceProxyResponse
    case Pay_FinishPayment
    case Pay_SendRecoveryScene

    // Music
    case Music_Play // 播放音乐
    case Music_Pause // 暂停音乐
    case Music_Next // 下一首音乐
    case Music_Prev // 上一首音乐
    case Music_FullLyrics // 音乐歌词
    case Music_QPlayState // QPlay连接状态

    // Journey
    case Journey_Add // 增加/更新行程，手机将增加/更新行程发送给眼镜
    case Journey_Remove // 删除行程，手机将待删除行程发送给眼镜
    case Journey_Sync // 同步所有行程，手机在每次连接后将所有行程同步给眼镜端
    case Journey_Reminder // 提醒行程，眼镜将待出发行程发送给手机

    case Order_Update // 点咖啡 手机发送给眼镜

    //Wifi
    case Wifi_StartGetWifiList
    case Wifi_StopGetWifiList
    case Wifi_UpdateWifiList
    case Wifi_Connect
    case Wifi_Connect_Status
    case Wifi_Disconnect
    case Wifi_Status

    case Live_PauseByPhone // 手机->眼镜 暂停
    case Live_PauseByGlasses // 眼镜->手机 暂停
    case Live_ResumeByPhone // 手机->眼镜 恢复
    case Live_SyncByPhone // 手机->眼镜 同步直播状态
    case Live_SyncByGlasses // 眼镜->手机 同步直播状态
    case Live_StopByGlasses // 眼镜->手机 结束直播
    case Live_GetStatusByPhone // 手机->眼镜  查询眼镜端直播状态

    // Jsai
    case Jsai_AddNativeAgent // 手机 -> 眼镜 添加智能体
    case Jsai_RemoveNativeAgent // 手机 -> 眼镜 删除智能体
    case Jsai_GetNativeAgentList // 手机 -> 眼镜 智能体列表发送给眼镜
    case Jsai_GetRequestInfo // 眼镜 -> 手机 获取agent请求信息
    case Jsai_SendA2UIInfo // 手机->眼镜  发送A2UI信息

    /// Accessibility
    case Accessibility_start
    case Accessibility_ASR
    case Accessibility_end
    case Accessibility_config

    /// 网络代理
    case Proxy_NetRequest // 眼镜->手机 眼镜端的网络请求，需要手机端代理
    case Proxy_NetResponse // 手机->眼镜 手机端代理眼镜端的网络请求，结果返回

    // Ntf
    case Ntf_SendNewMsg // 手机有新的信息，发送给眼镜
    case Ntf_ExecuteAgentCommand // 眼镜发送需要执行的智能体消息到手机端具体执行

}

public enum RGCxrCmd: String {
    case Dev
    case Med
    case Ota
    case Ai
    case Ntf
    case Nav
    case Tra
    case Sys
    case ARTC
    case Trans
    case Other
    case Settings
    case Schedule
    case Memo
    case Custom_View
    case Pay
    case Music
    case Journey
    case Order
    case Wifi
    case Broadcast
    case Jsai
    case Accessibility
    case Proxy
}

public struct RGCxrDeviceInfo {
    public let deviceName: String?
    public let batteryLevel: Int?
    public let sound: Int?
    public let brightness: Int?
    public let systemVersion: String?
    public let isCharging: Bool?
    public let sn: String?
    public let wearingStatus: Bool

    public init(deviceName: String?,
                batteryLevel: Int?,
                sound: Int?,
                brightness: Int?,
                systemVersion: String?,
                isCharging: Bool?,
                sn: String?,
                wearingStatus: Bool) {
        self.deviceName = deviceName
        self.batteryLevel = batteryLevel
        self.sound = sound
        self.brightness = brightness
        self.systemVersion = systemVersion
        self.isCharging = isCharging
        self.sn = sn
        self.wearingStatus = wearingStatus
    }

    public var dictionary: [String: Any] {
        var data: [String: Any] = [
            "wearingStatus": wearingStatus
        ]
        if let deviceName { data["deviceName"] = deviceName }
        if let batteryLevel { data["batteryLevel"] = batteryLevel }
        if let sound { data["sound"] = sound }
        if let brightness { data["brightness"] = brightness }
        if let systemVersion { data["systemVersion"] = systemVersion }
        if let isCharging { data["ischarging"] = isCharging }
        if let sn { data["sn"] = sn }
        return data
    }

    public static func from(dictionary data: [String: Any]) -> RGCxrDeviceInfo {
        RGCxrDeviceInfo(
            deviceName: data["deviceName"] as? String,
            batteryLevel: data["batteryLevel"] as? Int,
            sound: data["sound"] as? Int,
            brightness: data["brightness"] as? Int,
            systemVersion: data["systemVersion"] as? String,
            isCharging: data["ischarging"] as? Bool,
            sn: data["sn"] as? String,
            wearingStatus: (data["wearingStatus"] as? Bool) ?? false
        )
    }
}

public enum RGCxrAudioCodec: UInt32 {
    case pcm = 1
    case oggOpus
    case mp3
}

public enum RGCxrAudioMode: UInt32 {
    // 讯飞
    case xf = 1
    // 蚂蚁近场
    case antClose
    // Rokid自研全向
    case rokidOmni
    // 蚂蚁全向
    case antOmni
    // 讯飞定向
    case xfOrientation
    // 无障碍模式
    case barrierFree
}

// MARK: - 请求/响应类型
public enum RGCxrMessageType: String, Codable {
    case auth = "auth"                      // 鉴权请求
    case authResponse = "auth_response"     // 鉴权响应
    case startSession = "start_session"     // 创建 session 请求
    case sessionResponse = "session_response" // session 响应
    case heartbeat = "heartbeat"            // 心跳
    case heartbeatAck = "heartbeat_ack"     // 心跳回复
    case endSession = "end_session"         // 结束 session
    case data = "data"                      // 数据传输
}

// MARK: - 鉴权状态
public enum RGCxrAuthStatus: String, Codable {
    case pending = "pending"       // 等待鉴权
    case authorized = "authorized" // 已授权
    case denied = "denied"         // 拒绝
    case expired = "expired"       // 已过期
}

// MARK: - 基础消息结构
public struct RGCxrMessage: Codable {
    public let type: RGCxrMessageType
    public let sessionId: String?
    public let timestamp: TimeInterval
    public let payload: [String: AnyCodable]?

    public init(type: RGCxrMessageType, sessionId: String? = nil, payload: [String: AnyCodable]? = nil) {
        self.type = type
        self.sessionId = sessionId
        self.timestamp = Date().timeIntervalSince1970
        self.payload = payload
    }

    public func toData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func from(data: Data) -> RGCxrMessage? {
        try? JSONDecoder().decode(RGCxrMessage.self, from: data)
    }
}

// MARK: - 鉴权响应
public struct RGCxrAuthResponse: Codable {
    public let status: RGCxrAuthStatus
    public let token: String?        // 鉴权 token，后续请求需携带
    public let message: String?
    public let expiresAt: TimeInterval? // 过期时间

    public init(status: RGCxrAuthStatus, token: String? = nil, message: String? = nil, expiresAt: TimeInterval? = nil) {
        self.status = status
        self.token = token
        self.message = message
        self.expiresAt = expiresAt
    }
}

// MARK: - Session 请求
public struct RGCxrSessionRequest: Codable {
    public let authToken: String     // 鉴权 token
    public let bundleId: String
    public let metadata: [String: String]?

    public init(authToken: String, bundleId: String, metadata: [String: String]? = nil) {
        self.authToken = authToken
        self.bundleId = bundleId
        self.metadata = metadata
    }
}

// MARK: - Session 响应
public struct RGCxrSessionResponse: Codable {
    public let success: Bool
    public let sessionId: String?
    public let tcpPort: UInt16?      // 分配的 TCP 端口
    public let heartbeatInterval: TimeInterval // 心跳间隔（秒）
    public let message: String?

    public init(success: Bool, sessionId: String? = nil, tcpPort: UInt16? = nil, heartbeatInterval: TimeInterval = 5.0, message: String? = nil) {
        self.success = success
        self.sessionId = sessionId
        self.tcpPort = tcpPort
        self.heartbeatInterval = heartbeatInterval
        self.message = message
    }
}

// MARK: - AnyCodable 用于处理动态类型
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
