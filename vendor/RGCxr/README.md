# RGCxr IPC 通信技术方案

## 目录

1. [概述](#1-概述)
2. [整体架构设计](#2-整体架构设计)
3. [通信协议定义](#3-通信协议定义)
4. [连接建立流程](#4-连接建立流程)
5. [音频传输流程](#5-音频传输流程)
6. [错误处理机制](#6-错误处理机制)
7. [API 设计](#7-api 设计)
8. [使用示例](#8-使用示例)
9. [性能指标](#9-性能指标)
10. [附录](#10-附录)

---

## 1. 概述

### 1.1 项目背景

RGCxr 模块是 Rokid AI Glasses iOS 系统中用于实现两个 APP(Rokid AI 与 CXR-L) 之间进程间通信 (IPC) 的核心组件。该系统通过蓝牙外设 (Glasses) 作为消息中转站，实现双向通信。

**核心场景:**
- **Rokid AI → 蓝牙外设 → CXR-L**: Rokid AI 通过蓝牙通道向 CXR-L 发送控制指令
- **CXR-L → 蓝牙外设 → Rokid AI**: CXR-L 通过蓝牙通道向 Rokid AI 发送状态更新
- **音频流传输**: 通过 localhost TCP 传输音频数据，同时通过蓝牙心跳保活

### 1.2 术语定义

| 术语 | 定义 |
|------|------|
| RGCxrKit | Rokid AI 端的蓝牙连接层 SDK，负责与眼镜建立 BLE/MFi 连接（包含完整配对逻辑） |
| RGCxrServer | Rokid AI 端的 IPC Server，处理鉴权和 Session 管理 |
| RGCxrClient | CXR-L 端的 IPC Client，包含轻量级 BLE 连接能力 |
| RGCxrClientBLE | RGCxrClient 内部的轻量级 BLE 模块，仅包含基础 BLE 通信 |
| Glasses | 蓝牙外设，作为消息中转站 |
| Session | 蓝牙连接建立后的逻辑通信状态 |
| 心跳 | 在音频传输期间通过蓝牙发送的保活消息 |

### 1.3 设计原则

1. **蓝牙为主**: 所有业务数据通过蓝牙通道传输
2. **TCP 为辅**: 仅在音频传输时使用临时 TCP
3. **轻量鉴权**: 通过 URL Scheme + Callback 完成鉴权，无需 HTTP
4. **按需心跳**: 仅在音频传输时发送心跳
5. **模块独立**: RGCxrClient 独立实现，不依赖 RGCxrKit

---

## 2. 整体架构设计

### 2.1 系统架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                         iOS Device                              │
│  ┌─────────────────────┐              ┌─────────────────────┐  │
│  │    Rokid AI App     │              │     CXR-L App       │  │
│  │  ┌───────────────┐  │              │  ┌───────────────┐  │  │
│  │  │  RGCxrServer  │  │              │  │  RGCxrClient  │  │  │
│  │  │  (URL Scheme  │  │              │  │  + ClientBLE  │  │  │
│  │  │   鉴权)       │  │              │  │  (轻量级 BLE)  │  │  │
│  │  └───────┬───────┘  │              │  └───────────────┘  │  │
│  │          │          │              │                      │  │
│  │  ┌───────▼───────┐  │              │                      │  │
│  │  │   RGCxrKit    │  │              │                      │  │
│  │  │  (BLE Layer)  │  │              │                      │  │
│  │  └───────┬───────┘  │              │                      │  │
│  └──────────┼──────────┘              └──────────┼───────────┘  │
│             │                                    │              │
│             │         ┌─────────────────┐        │              │
│             │         │  iOS Bluetooth  │        │              │
│             └────────►│   (CoreBLE)     │◄───────┘              │
│                       └─────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
                          │     ▲
                          │ BLE │
                          ▼     │
                ┌───────────────────────┐
                │      Glasses          │
                │  (消息转发)            │
                └───────────────────────┘

注:
1. 鉴权通过 URL Scheme + Callback 完成，不使用 HTTP
2. 所有业务数据通过蓝牙通道传输
3. RGCxrClient 包含独立的轻量级 BLE 模块 (RGCxrClientBLE)
4. TCP 仅在音频传输时临时建立
```

### 2.2 组件职责

#### 2.2.1 RGCxrKit(蓝牙连接层 - Rokid AI 端)

**职责:**
- 负责与眼镜建立 BLE/MFi 连接
- 包含完整的配对、鉴权、重连逻辑
- 提供双向消息收发能力
- 提供音频流回调

**特点:**
- 重量级，包含完整的业务逻辑
- 仅用于 Rokid AI 端

#### 2.2.2 RGCxrServer(IPC Server - Rokid AI 端)

**职责:**
- 处理 URL Scheme 鉴权请求
- 鉴权通过后建立 Session(逻辑状态)
- 音频传输时分配临时 TCP 端口

**特点:**
- Session 是逻辑概念，不需要 HTTP
- 鉴权结果通过 URL Scheme Callback 返回
- 作为 Rokid AI 的内部模块，不对外暴露

#### 2.2.3 RGCxrClient(IPC Client - CXR-L 端)

**职责:**
- 通过 URL Scheme 拉起 Rokid AI
- 通过 URL Scheme Callback 接收鉴权结果
- 通过 RGCxrClientBLE 与眼镜建立 BLE 连接
- 通过蓝牙通道与 Rokid AI 通信

**组成:**
- `AuthManager`: URL Scheme 鉴权管理
- `RGCxrClientBLE`: 轻量级 BLE 通信模块
- `Session`: Session 状态管理
- `AudioStreamManager`: 音频流接收

**特点:**
- 轻量级，不依赖 RGCxrKit
- 独立实现 BLE 连接逻辑 (~500 行代码)
- 仅包含基础 BLE 通信能力，无配对逻辑

---

## 3. 通信协议定义

### 3.1 蓝牙消息格式

使用 RGCxrCore 定义的二进制协议格式，RGCxrKit 和 RGCxrClientBLE 共享相同的协议定义。

**详细定义参考:** [RGCxrProtocol.swift](./RGCxrCore/Classes/RGCxrProtocol.swift)

**主要枚举:**
- `RGCxrCmd`: 主命令类型 (Dev, Med, Ai, Nav, Trans 等)
- `RGCxrSubCmd`: 子命令 (具体的业务指令)

**使用示例:**
```swift
// RGCxrKit (Rokid AI 端)
RGCxrKit.shared.send(
    cmd: .Ai,           // 主命令
    subCmd: .KeyDown,   // 子命令
    data: nil
)

// RGCxrClientBLE (CXR-L 端)
RGCxrClient.shared.send(
    cmd: .Ai,
    subCmd: .KeyDown,
    data: nil
)
```

### 3.2 URL Scheme 鉴权协议

#### 3.2.1 鉴权请求 (CXR-L → Rokid AI)

```
rokidai://connect?bundleId=com.rokid.cxrl&scopes=device_control,audio_stream&nonce=xxx&timestamp=1234567890&callback=cxrl://auth/callback
```

**参数说明:**

| 参数 | 必填 | 说明 |
|------|------|------|
| bundleId | ✓ | CXR-L 的包名 |
| scopes | ✓ | 申请的权限范围，逗号分隔 |
| nonce | ✓ | 随机字符串，防止重放攻击 |
| timestamp | ✓ | Unix 时间戳，用于验证请求时效性 |
| callback | ✓ | 鉴权结果回调 URL Scheme |

#### 3.2.2 鉴权响应 (Rokid AI → CXR-L)

**鉴权成功:**
```
cxrl://auth/callback?success=true&token=auth-token-string&sessionId=uuid-string
```

**鉴权失败:**
```
cxrl://auth/callback?success=false&error=auth_failed&message=error message
```

### 3.3 Session 定义

**Session = 鉴权通过 + 蓝牙连接正常**

Session 是逻辑状态，不需要维持 HTTP 连接：

```swift
struct Session {
    let sessionId: String      // UUID
    let bundleId: String       // Client 包名
    let createdAt: Date        // 创建时间
    var isBluetoothConnected: Bool  // 蓝牙连接状态
}
```

---

## 4. 连接建立流程

### 4.1 整体流程

```
┌─────────┐      ┌─────────┐      ┌─────────┐
│  CXR-L  │      │ Glasses │      │RGCxrKit │
│ (Client)│      │         │      │         │
└────┬────┘      └────┬────┘      └────┬────┘
     │                │                │
     │ 1.URL Scheme   │                │
     │───────────────►│                │
     │  (含 callback)  │                │
     │                │                │
     │                │ 2. 蓝牙已连接   │
     │                │───────────────►│
     │                │                │
     │                │ 3. 验证鉴权    │
     │                │───────────┐    │
     │                │           │    │
     │                │           ▼    │
     │                │      创建 Session │
     │                │                │
     │                │ 4.URL Scheme Callback
     │◄───────────────────────────────│
     │   (success=true&token=xxx)     │
     │                │                │
     │ 5.Session 建立  │                │
     │◄───────────────│────────────────│
     │   (蓝牙通道)    │                │
     │                │                │
     │◄═══════════════│═══════════════►│
     │   蓝牙通信开始   │                │
     │                │                │
```

### 4.2 URL Scheme 拉起与鉴权

**CXR-L 发起:**

```swift
// CXR-L 端
func connectToRokidAI() {
    var components = URLComponents()
    components.scheme = "rokidai"
    components.host = "connect"
    components.queryItems = [
        URLQueryItem(name: "bundleId", value: Bundle.main.bundleIdentifier!),
        URLQueryItem(name: "scopes", value: "device_control,audio_stream"),
        URLQueryItem(name: "nonce", value: UUID().uuidString),
        URLQueryItem(name: "timestamp", value: "\(Int(Date().timeIntervalSince1970))"),
        URLQueryItem(name: "callback", value: "cxrl://auth/callback")
    ]
    
    guard let url = components.url else { return }
    
    if UIApplication.shared.canOpenURL(url) {
        UIApplication.shared.open(url)
    }
}
```

**Rokid AI 处理鉴权:**

```swift
// Rokid AI 端
func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
    guard url.scheme == "rokidai", url.host == "connect" else {
        return false
    }
    
    // 解析参数
    let params = parseURLParams(url)
    
    // 1. 验证时间戳 (5 分钟内有效)
    guard let timestamp = Double(params["timestamp"] ?? ""),
          Date().timeIntervalSince1970 - timestamp < 300 else {
        sendAuthCallback(callback: params["callback"]?, success: false, error: "timestamp_expired")
        return false
    }
    
    // 2. 验证 nonce (防止重放攻击)
    guard NonceManager.shared.verify(params["nonce"] ?? "") else {
        sendAuthCallback(callback: params["callback"]?, success: false, error: "invalid_nonce")
        return false
    }
    
    // 3. 检查蓝牙连接状态
    guard RGCxrKit.shared.isBluetoothConnected else {
        // 蓝牙未连接，等待连接后再鉴权
        pendingAuthParams = params
        waitForBluetoothConnection()
        return true
    }
    
    // 4. 执行鉴权
    performAuth(params: params)
    
    return true
}

private func performAuth(params: [String: String]) {
    // 验证 bundleId 是否在白名单
    let bundleId = params["bundleId"] ?? ""
    guard isBundleIdAllowed(bundleId) else {
        sendAuthCallback(callback: params["callback"], success: false, error: "bundleId_not_allowed")
        return
    }
    
    // 创建 Session
    let session = Session(
        sessionId: UUID().uuidString,
        bundleId: bundleId,
        scopes: params["scopes"]?.components(separatedBy: ",") ?? [],
        createdAt: Date()
    )
    SessionManager.shared.addSession(session)
    
    // 通过 URL Scheme Callback 返回鉴权结果
    sendAuthCallback(
        callback: params["callback"],
        success: true,
        token: session.sessionId,
        sessionId: session.sessionId
    )
}

private func sendAuthCallback(callback: String?, success: Bool, token: String? = nil, sessionId: String? = nil, error: String? = nil) {
    guard let callback = callback, var components = URLComponents(string: callback) else {
        return
    }
    
    var queryItems: [URLQueryItem] = [URLQueryItem(name: "success", value: "\(success)")]
    
    if success {
        if let token = token {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        if let sessionId = sessionId {
            queryItems.append(URLQueryItem(name: "sessionId", value: sessionId))
        }
    } else if let error = error {
        queryItems.append(URLQueryItem(name: "error", value: error))
    }
    
    components.queryItems = queryItems
    
    if let callbackUrl = components.url,
       UIApplication.shared.canOpenURL(callbackUrl) {
        UIApplication.shared.open(callbackUrl)
    }
}
```

### 4.3 CXR-L 处理鉴权回调

```swift
// CXR-L 端
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
        guard url.scheme == "cxrl", url.host == "auth", url.path == "/callback" else {
            return false
        }
        
        // 解析回调参数
        let params = parseURLParams(url)
        
        if params["success"] == "true" {
            // 鉴权成功
            let token = params["token"] ?? ""
            let sessionId = params["sessionId"] ?? ""
            
            // Session 建立完成
            SessionManager.shared.sessionEstablished(token: token, sessionId: sessionId)
            
            // 开始通过蓝牙通信
            startBluetoothCommunication()
        } else {
            // 鉴权失败
            let error = params["error"] ?? "unknown_error"
            handleAuthFailed(error: error)
        }
        
        return true
    }
}
```

### 4.4 Session 建立后的通信

**Session 建立后，所有通信通过蓝牙:**

```swift
// Rokid AI → CXR-L
RGCxrKit.shared.send(
    cmd: .Ai,
    subCmd: .KeyDown,
    data: data
)

// CXR-L → Rokid AI  
RGCxrKit.shared.send(
    cmd: .Ai,
    subCmd: .KeyUp,
    data: data
)
```

---

## 5. 音频传输流程

### 5.1 音频传输概述

**重要:**
- TCP 连接**仅在音频传输时建立**
- 音频传输期间通过**蓝牙发送心跳**保活
- 音频结束后，TCP 连接和心跳都停止

### 5.2 音频传输流程

```
Rokid AI           Glasses           CXR-L
   │                  │                 │
   │ 1.开启拾音       │                 │
   │─────────────────►│                 │
   │                  │                 │
   │                  │ 2. 拾音开始通知 │
   │                  │────────────────►│
   │                  │                 │
   │ 3.启动 TCP Server│                 │
   │   (动态端口)      │                 │
   │                  │                 │
   │ 4. 通知 TCP 端口   │                 │
   │─────────────────►│                 │
   │                  │ 5. 端口通知     │
   │                  │────────────────►│
   │                  │                 │
   │                  │                 │ 6.TCP 连接
   │                  │                 │────────┐
   │                  │                 │        │
   │◄─────────────────│─────────────────│────────┘
   │  TCP Connected   │                 │
   │                  │                 │
   │======================音频流传输开始================══│
   │                  │                 │
   │◄─────音频数据────│─────────────────│  (TCP)
   │                  │                 │
   │◄─────心跳 (5s)───│─────────────────│  (蓝牙)
   │                  │                 │
   │                  │                 │
   │ 7. 音频结束      │                 │
   │─────────────────►│                 │
   │                  │                 │
   │                  │ 8. 结束通知     │
   │                  │────────────────►│
   │                  │                 │
   │ 9.关闭 TCP Server│                 │
   │                  │                 │
   │ 10.关闭拾音      │                 │
   │─────────────────►│                 │
   │                  │                 │
   │======================音频传输结束================══│
   │                  │                 │
```

### 5.3 心跳机制

**仅在音频传输期间发送心跳:**

```swift
// Rokid AI 端
class AudioStreamingManager {
    private var heartbeatTimer: Timer?
    
    func startStreaming() {
        // 启动音频传输
        startAudioCapture()
        
        // 启动心跳 (每 5 秒通过蓝牙发送)
        startHeartbeat()
    }
    
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            // 通过蓝牙发送心跳
            RGCxrKit.shared.send(
                cmd: .Ai,
                subCmd: .Ai_Heartbeat,
                data: nil
            )
        }
    }
    
    func stopStreaming() {
        // 停止音频传输
        stopAudioCapture()
        
        // 停止心跳
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}
```

**心跳超时处理:**

```swift
// CXR-L 端
class AudioStreamReceiver {
    private var lastHeartbeatTime: Date?
    private var heartbeatTimeout: TimeInterval = 15.0
    
    func onHeartbeatReceived() {
        lastHeartbeatTime = Date()
    }
    
    func checkHeartbeatTimeout() {
        guard let lastTime = lastHeartbeatTime else { return }
        
        if Date().timeIntervalSince(lastTime) > heartbeatTimeout {
            // 心跳超时，停止音频接收
            stopAudioStreaming()
        }
    }
}
```

### 5.4 TCP 音频传输

**Rokid AI 端:**

```swift
// 启动临时 TCP Server
class AudioTCPServer {
    private var server: TCPServer?
    
    func start() -> UInt16 {
        // 动态分配端口
        server = TCPServer(port: 0)
        return server?.port ?? 0
    }
    
    func onClientConnected(_ handler: @escaping (TCPConnection) -> Void) {
        server?.onAccept = handler
    }
    
    func send(data: Data) {
        // 发送音频数据
    }
    
    func stop() {
        server?.close()
        server = nil
    }
}

// 使用示例
func startAudioStreaming() {
    // 1. 开启拾音 (通过蓝牙)
    RGCxrKit.shared.openAudioRecord(type: "AI_assistant")
    
    // 2. 启动 TCP Server
    let audioServer = AudioTCPServer()
    let port = audioServer.start()
    
    // 3. 通知 CXR-L(通过蓝牙)
    RGCxrKit.shared.send(
        cmd: .Ai,
        subCmd: .Ai_StartAudioStream,
        data: ["tcpPort": port]
    )
    
    // 4. 等待 CXR-L 连接
    audioServer.onClientConnected { connection in
        // 开始传输音频
        RGCxrKit.shared.addAudioStreamDelegate(self)
    }
    
    // 5. 启动心跳
    startHeartbeat()
}
```

**CXR-L 端:**

```swift
// 接收 TCP 音频流
class AudioStreamClient {
    private var connection: TCPConnection?
    
    func connect(port: UInt16) {
        connection = TCPConnection(host: "127.0.0.1", port: port)
        connection?.onData = { [weak self] data in
            self?.handleAudioData(data)
        }
    }
    
    private func handleAudioData(_ data: Data) {
        // 处理音频数据
        audioPlayer.play(data)
    }
}

// 处理音频开始通知 (通过蓝牙)
func onAudioStreamNotification(_ params: [String: Any]) {
    if let port = params["tcpPort"] as? UInt16 {
        // 连接 TCP 接收音频
        audioStreamClient.connect(port: port)
    }
}
```

---

## 6. 错误处理机制

### 6.1 错误类型

```swift
enum RGCxrError: LocalizedError {
    // 鉴权错误
    case authFailed(String)
    case authExpired
    case invalidNonce
    
    // 连接错误
    case bluetoothDisconnected
    case tcpConnectionFailed
    case sessionNotFound
    
    // 音频错误
    case audioStreamFailed
    case heartbeatTimeout
}
```

### 6.2 错误恢复

#### 6.2.1 蓝牙断开重连

```swift
RGCxrKit.shared.addConnectionDelegate(delegate)

protocol RGCxrConnectionDelegate {
    func onBluetoothDisconnected()
    func onBluetoothReconnecting()
    func onBluetoothReconnected()
}

// 实现重连
func onBluetoothDisconnected() {
    // 1. 标记 Session 为断开状态
    SessionManager.shared.markSessionDisconnected()
    
    // 2. 如果是音频传输中，暂停音频
    if isAudioStreaming {
        pauseAudioStreaming()
    }
    
    // 3. 触发重连
    RGCxrKit.shared.reconnect()
}
```

#### 6.2.2 Session 恢复

```swift
// 蓝牙重连成功后
func onBluetoothReconnected() {
    // 1. 验证 Session 是否仍然有效
    if SessionManager.shared.currentSession != nil {
        // Session 仍然有效，恢复通信
        resumeCommunication()
    } else {
        // Session 已失效，需要重新鉴权
        restartAuthFlow()
    }
}
```

### 6.3 边界条件处理

#### 6.3.1 应用进入后台

```swift
// 应用进入后台
func applicationDidEnterBackground() {
    // 如果正在音频传输，继续通过蓝牙发送心跳
    if isAudioStreaming {
        continueHeartbeat()
    }
}

// 应用被杀死前
func applicationWillTerminate() {
    // 停止所有传输
    stopAudioStreaming()
    
    // 断开蓝牙
    RGCxrKit.shared.disconnect()
}
```

#### 6.3.2 内存警告

```swift
func didReceiveMemoryWarning() {
    // 如果不是关键状态，释放资源
    if !isAudioStreaming {
        releaseUnusedResources()
    }
}
```

---

## 7. API 设计

### 7.1 RGCxrKit API

```swift
// 单例
let kit = RGCxrKit.shared

// 初始化
func setup()

// 连接管理
func connect(to serialNumber: String, new: Bool)
func disconnect()
func reconnect()

// 数据发送
func send(cmd: RGCxrCmd, subCmd: RGCxrSubCmd, data: Any?)
func send(cmd: String, subCmd: String, data: Any?)

// 音频控制
func openAudioRecord(type: String, codec: RGCxrAudioCodec, mode: RGCxrAudioMode)
func closeAudioRecord(type: String)
func addAudioStreamDelegate(_ delegate: RGCxrAudioStreamDelegate)

// 回调
var connectionStatusPublisher: AnyPublisher<Bool, Never> { get }
```

### 7.2 Session 管理 API

```swift
// 单例
let sessionManager = SessionManager.shared

// Session 状态
var currentSession: Session? { get }
var isSessionEstablished: Bool { get }

// Session 生命周期
func sessionEstablished(token: String, sessionId: String)
func sessionTerminated()

// 鉴权管理
func grantAuthorization(for bundleId: String)
func revokeAuthorization(for bundleId: String)
func isBundleIdAllowed(_ bundleId: String) -> Bool
```

---

## 8. 使用示例

### 8.1 配置 URL Schemes

#### Rokid AI (Info.plist)

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.rokid.ai</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>rokidai</string>
        </array>
    </dict>
</array>
```

#### CXR-L (Info.plist)

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>rokidai</string>
</array>
</key>
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.rokid.cxrl</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>cxrl</string>
        </array>
    </dict>
</array>
```

### 8.2 Rokid AI 端完整示例

```swift
import RGCxrKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication, 
                     didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
        // 初始化蓝牙
        RGCxrKit.shared.setup()
        
        // 监听蓝牙连接状态
        RGCxrKit.shared.connectionStatusPublisher
            .sink { [weak self] connected in
                if connected {
                    // 蓝牙连接成功，如果有待处理的鉴权请求，继续处理
                    self?.processPendingAuth()
                }
            }
            .store(in: &cancellables)
        
        return true
    }
    
    // 处理 URL Scheme 鉴权请求
    func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
        guard url.scheme == "rokidai", url.host == "connect" else {
            return false
        }
        
        // 解析参数
        let params = parseURLParams(url)
        
        // 验证时间戳
        guard let timestamp = Double(params["timestamp"] ?? ""),
              Date().timeIntervalSince1970 - timestamp < 300 else {
            sendAuthCallback(callback: params["callback"], success: false, error: "timestamp_expired")
            return false
        }
        
        // 验证 nonce
        guard NonceManager.shared.verify(params["nonce"] ?? "") else {
            sendAuthCallback(callback: params["callback"], success: false, error: "invalid_nonce")
            return false
        }
        
        // 检查蓝牙连接状态
        if !RGCxrKit.shared.isBluetoothConnected {
            // 蓝牙未连接，保存参数等待连接后处理
            pendingAuthParams = params
            return true
        }
        
        // 执行鉴权
        performAuth(params: params)
        
        return true
    }
    
    private func performAuth(params: [String: String]) {
        let bundleId = params["bundleId"] ?? ""
        
        // 验证 bundleId
        guard isBundleIdAllowed(bundleId) else {
            sendAuthCallback(callback: params["callback"], success: false, error: "bundleId_not_allowed")
            return
        }
        
        // 创建 Session
        let session = Session(
            sessionId: UUID().uuidString,
            bundleId: bundleId,
            scopes: params["scopes"]?.components(separatedBy: ",") ?? []
        )
        SessionManager.shared.addSession(session)
        
        // 返回鉴权结果
        sendAuthCallback(
            callback: params["callback"],
            success: true,
            token: session.sessionId,
            sessionId: session.sessionId
        )
    }
    
    // 发送命令到 CXR-L(通过蓝牙)
    func sendCommandToCxrL() {
        RGCxrKit.shared.send(
            cmd: .Ai,
            subCmd: .KeyDown,
            data: nil
        )
    }
    
    // 开启音频传输
    func startAudioStreaming() {
        // 1. 开启拾音 (通过蓝牙)
        RGCxrKit.shared.openAudioRecord(
            type: "AI_assistant",
            codec: .oggOpus,
            mode: .rokidOmni
        )
        
        // 2. 启动 TCP Server
        let port = audioServer.start()
        
        // 3. 通知 CXR-L(通过蓝牙)
        RGCxrKit.shared.send(
            cmd: .Ai,
            subCmd: .Ai_StartAudioStream,
            data: ["tcpPort": port]
        )
        
        // 4. 启动心跳 (通过蓝牙)
        startHeartbeat()
    }
    
    // 停止音频传输
    func stopAudioStreaming() {
        // 1. 通知 CXR-L(通过蓝牙)
        RGCxrKit.shared.send(
            cmd: .Ai,
            subCmd: .Ai_EndAudioStream,
            data: nil
        )
        
        // 2. 停止心跳
        stopHeartbeat()
        
        // 3. 关闭 TCP Server
        audioServer.stop()
        
        // 4. 关闭拾音 (通过蓝牙)
        RGCxrKit.shared.closeAudioRecord(type: "AI_assistant")
    }
}
```

### 8.3 CXR-L 端完整示例

```swift
import RGCxrKit

class CXRService {
    
    // 拉起 Rokid AI 并鉴权
    func connectToRokidAI() {
        var components = URLComponents()
        components.scheme = "rokidai"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: Bundle.main.bundleIdentifier!),
            URLQueryItem(name: "scopes", value: "device_control,audio_stream"),
            URLQueryItem(name: "nonce", value: UUID().uuidString),
            URLQueryItem(name: "timestamp", value: "\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "callback", value: "cxrl://auth/callback")
        ]
        
        guard let url = components.url else { return }
        
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
    
    // 处理鉴权回调
    func handleAuthCallback(url: URL) {
        let params = parseURLParams(url)
        
        if params["success"] == "true" {
            // 鉴权成功
            let token = params["token"] ?? ""
            let sessionId = params["sessionId"] ?? ""
            
            // Session 建立完成
            SessionManager.shared.sessionEstablished(token: token, sessionId: sessionId)
            
            // 开始通过蓝牙通信
            startBluetoothCommunication()
        } else {
            // 鉴权失败
            let error = params["error"] ?? "unknown_error"
            handleAuthFailed(error: error)
        }
    }
    
    // 接收来自 Rokid AI 的命令 (通过蓝牙)
    func onCommandReceived(cmd: String, subCmd: String, data: Any?) {
        // 处理命令
    }
    
    // 接收音频流通知 (通过蓝牙)
    func onAudioStreamNotification(params: [String: Any]) {
        if let port = params["tcpPort"] as? UInt16 {
            // 连接 TCP 接收音频
            connectToAudioServer(port: port)
        }
    }
}
```

---

## 9. 性能指标

### 9.1 延迟要求

| 场景 | 目标延迟 | 最大延迟 |
|------|----------|----------|
| 蓝牙命令传输 | < 50ms | < 100ms |
| 蓝牙状态通知 | < 50ms | < 100ms |
| 音频端到端延迟 | < 100ms | < 200ms |
| TCP 音频传输 | < 10ms | < 30ms |

### 9.2 吞吐量要求

| 场景 | 目标吞吐量 | 通道 |
|------|------------|------|
| 蓝牙命令 | 100 msg/s | BLE/MFi |
| 蓝牙状态通知 | 50 msg/s | BLE/MFi |
| 音频流 | 32 KB/s | TCP |
| 心跳 | 1 msg/5s | BLE/MFi |

### 9.3 资源占用

| 资源 | 限制 |
|------|------|
| 内存占用 | < 50MB (包含音频缓冲) |
| CPU 占用 | < 5% (空闲时), < 20% (音频传输时) |
| 蓝牙带宽 | < 10 KB/s (心跳 + 控制) |

---

## 10. 附录

### A. 协议枚举

```swift
enum RGCxrCmd: String {
    case Dev, Med, Ota, Ai, Ntf, Nav, Tra, Sys, ARTC
    case Trans, Other, Settings, Schedule, Memo
    case Custom_View, Pay, Music, Journey, Order
    case Wifi, Broadcast
}

enum RGCxrSubCmd: String {
    // AI
    case KeyDown, KeyUp, Exit
    case ASR_Result, TTS_Result
    case Ai_Heartbeat, Ai_StartAudioStream
    // ... 更多参考 RGCxrProtocol.swift
}
```

### B. 错误码

| 错误码 | 含义 |
|--------|------|
| -1199 | 连接断开 |
| -1000 | 请求超时 |
| -1 | 通用错误 |

### C. 参考资料

- [RGCxrProtocol.swift](./RGCxrCore/Classes/RGCxrProtocol.swift)
- [iOS 保活策略.md](./iOS 保活策略.md)
