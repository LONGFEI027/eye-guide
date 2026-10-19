# RGCxrClient 架构设计文档

## 目录

1. [概述](#1-概述)
2. [架构设计](#2-架构设计)
3. [核心模块](#3-核心模块)
4. [鉴权流程](#4-鉴权流程)
5. [蓝牙通信](#5-蓝牙通信)
6. [音频接收](#6-音频接收)
7. [错误处理](#7-错误处理)
8. [API 设计](#8-api 设计)

---

## 1. 概述

### 1.1 模块定位

RGCxrClient 是 CXR-L App 的 IPC 客户端模块，用于与 Rokid AI App 进行进程间通信。

**核心职责:**
- 通过 URL Scheme 拉起 Rokid AI 并发起鉴权
- 通过 URL Scheme Callback 接收鉴权结果
- 通过蓝牙通道与 Rokid AI 进行双向通信
- 接收音频流数据 (通过临时 TCP)

### 1.2 设计原则

1. **轻量级**: 仅包含必要的鉴权和通信逻辑
2. **事件驱动**: 基于 Combine/Publisher-Subscriber 模式
3. **异步非阻塞**: 所有操作异步执行，不阻塞主线程
4. **自动重连**: 支持蓝牙断开后的自动重连

### 1.3 依赖关系

```
RGCxrClient
├── RGCoreKit (日志、扩展)
├── Combine (响应式框架)
└── CoreBluetooth (系统框架)

注：不依赖 RGCxrKit，独立实现轻量级 BLE 连接
```

### 1.4 模块独立性

**为什么 RGCxrClient 不依赖 RGCxrKit？**

1. **RGCxrKit 太重**: 包含完整的配对、鉴权、重连逻辑
2. **职责不同**: RGCxrClient 只需要基础 BLE 通信，不需要配对逻辑
3. **独立演进**: 两个模块可以独立开发和升级

**RGCxrClientBLE (轻量级 BLE 模块):**
- 仅包含基础 BLE 连接和消息收发
- 不包含配对、鉴权等复杂逻辑
- 代码量小，易于维护

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────┐
│              CXR-L Application                  │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │           RGCxrClient                   │   │
│  │  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │ AuthManager │  │ Session         │  │   │
│  │  │ (鉴权管理)   │  │ (Session 对象)   │  │   │
│  │  └─────────────┘  └─────────────────┘  │   │
│  │  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │URLSchemeMgr │  │ RGCxrClientBLE  │  │   │
│  │  │(URL 处理)    │  │ (轻量级 BLE)    │  │   │
│  │  └─────────────┘  └─────────────────┘  │   │
│  │  ┌─────────────┐                        │   │
│  │  │AudioStream  │                        │   │
│  │  │(音频接收)   │                        │   │
│  │  └─────────────┘                        │   │
│  └─────────────────────────────────────────┘   │
│         │                                       │
│         ▼                                       │
│  ┌─────────────┐                               │
│  │CoreBluetooth│ (系统 BLE 框架)                 │
│  └─────────────┘                               │
└─────────────────────────────────────────────────┘

注：RGCxrClientBLE 是 RGCxrClient 内部的轻量级 BLE 模块
   不依赖 RGCxrKit，独立实现
```

### 2.2 模块分层

```
┌──────────────────────────────────────┐
│        Business Layer                │
│     (业务逻辑层 - CXR-L 自己实现)      │
├──────────────────────────────────────┤
│        RGCxrClient                   │
│     (IPC 客户端层)                    │
│  ┌────────────────────────────────┐  │
│  │  Public API                    │  │
│  └────────────────────────────────┘  │
├──────────────────────────────────────┤
│        RGCxrKit                      │
│     (蓝牙连接层)                      │
│  ┌────────────────────────────────┐  │
│  │  BLE/MFi Connection            │  │
│  │  Protocol Encoding/Decoding    │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

---

## 3. 核心模块

### 3.1 AuthManager (鉴权管理)

**职责:**
- 构建 URL Scheme 鉴权请求
- 处理 URL Scheme Callback 鉴权结果
- 管理鉴权状态

**状态机:**
```
┌─────────┐   发起鉴权   ┌─────────────┐
│  Idle   │────────────►│  Pending    │
└─────────┘              │ (等待响应)  │
     ▲                   └──────┬──────┘
     │                          │
     │        ┌─────────────────┴─────────────┐
     │        │                               │
     │  鉴权失败│                       鉴权成功│
     │        │                               │
     └────────┴───────────────────────────────┘
              │
              ▼
       ┌─────────────┐
       │ Authorized  │
       └─────────────┘
```

**实现示例:**
```swift
class AuthManager {
    enum AuthState {
        case idle
        case pending
        case authorized(token: String, sessionId: String)
        case failed(error: String)
    }
    
    private(set) var state: AuthState = .idle
    private let stateSubject = PassthroughSubject<AuthState, Never>()
    
    var statePublisher: AnyPublisher<AuthState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    
    func authenticate(scopes: [String], callback: String) {
        // 1. 构建 URL
        let url = buildAuthURL(scopes: scopes, callback: callback)
        
        // 2. 更新状态
        state = .pending
        stateSubject.send(.pending)
        
        // 3. 拉起 Rokid AI
        UIApplication.shared.open(url)
    }
    
    func handleCallback(url: URL) -> Bool {
        // 解析鉴权结果
        let params = parseURLParams(url)
        
        if params["success"] == "true" {
            let token = params["token"] ?? ""
            let sessionId = params["sessionId"] ?? ""
            state = .authorized(token: token, sessionId: sessionId)
            stateSubject.send(.authorized(token: token, sessionId: sessionId))
            return true
        } else {
            let error = params["error"] ?? "unknown"
            state = .failed(error: error)
            stateSubject.send(.failed(error: error))
            return false
        }
    }
}
```

### 3.2 Session (Session 对象)

**设计说明:**
- 一个 Client 只有一个 Session 实例
- Session 作为 RGCxrClient 的内部属性
- Session 是逻辑状态，不需要单独管理

**Session 状态:**
```swift
enum SessionState {
    case notEstablished
    case established(token: String, sessionId: String)
    case bluetoothConnected
    case bluetoothDisconnected
    case terminated
}

struct Session {
    let sessionId: String
    let bundleId: String
    let token: String
    let createdAt: Date
    var state: SessionState
}
```

**实现示例:**
```swift
class RGCxrClient {
    static let shared = RGCxrClient()
    
    // Session 作为 Client 的属性，不是单独的管理器
    private(set) var session: Session?
    private let stateSubject = PassthroughSubject<SessionState, Never>()
    
    var statePublisher: AnyPublisher<SessionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    
    func sessionEstablished(token: String, sessionId: String) {
        let session = Session(
            sessionId: sessionId,
            bundleId: Bundle.main.bundleIdentifier!,
            token: token,
            createdAt: Date(),
            state: .established(token: token, sessionId: sessionId)
        )
        self.session = session
        stateSubject.send(.established(token: token, sessionId: sessionId))
    }
    
    func onBluetoothConnected() {
        session?.state = .bluetoothConnected
        stateSubject.send(.bluetoothConnected)
    }
    
    func onBluetoothDisconnected() {
        session?.state = .bluetoothDisconnected
        stateSubject.send(.bluetoothDisconnected)
    }
}
```

### 3.3 RGCxrClientBLE (轻量级 BLE 模块)

**职责:**
- 扫描并连接眼镜 BLE 设备
- 通过 BLE 发送和接收消息
- 不包含配对、鉴权等复杂逻辑

**与 RGCxrKit 的区别:**

| 特性 | RGCxrKit | RGCxrClientBLE |
|------|----------|----------------|
| 用途 | Rokid AI 端 | CXR-L 端 |
| 配对逻辑 | ✓ 完整支持 | ✗ 不需要 |
| MFi 支持 | ✓ 支持 | ✗ 仅 BLE |
| 重连逻辑 | ✓ 复杂策略 | ✗ 简单重连 |
| 代码量 | ~3000 行 | ~500 行 |
| 依赖 | 无 | RGCoreKit |

**BLE 连接流程:**
```
1. 扫描设备 (CBCentralManager)
2. 发现眼镜 (根据 Service UUID)
3. 连接设备
4. 发现 Service 和 Characteristic
5. 读写数据
```

**实现示例:**
```swift
class RGCxrClientBLE: NSObject {
    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var readCharacteristic: CBCharacteristic?
    
    private let stateSubject = PassthroughSubject<Bool, Never>()
    private let dataSubject = PassthroughSubject<Data, Never>()
    
    var connectionState: AnyPublisher<Bool, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    
    var rawData: AnyPublisher<Data, Never> {
        dataSubject.eraseToAnyPublisher()
    }
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func scanAndConnect() {
        centralManager?.scanForPeripherals(
            withServices: [RGCxrUUID.service.uuid],
            options: nil
        )
    }
    
    func send(data: Data) {
        guard let characteristic = writeCharacteristic,
              let peripheral = peripheral else {
            return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate
extension RGCxrClientBLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scanAndConnect()
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // 发现眼镜，停止扫描并连接
        centralManager?.stopScan()
        centralManager?.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([RGCxrUUID.service.uuid])
        stateSubject.send(true)
    }
}

// MARK: - CBPeripheralDelegate
extension RGCxrClientBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        // 发现 Service 后，发现 Characteristic
        if let services = peripheral.services {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        // 保存 Characteristic 用于后续读写
        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                if characteristic.uuid == RGCxrUUID.write.uuid {
                    writeCharacteristic = characteristic
                } else if characteristic.uuid == RGCxrUUID.read.uuid {
                    readCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // 接收数据
        if let data = characteristic.value {
            dataSubject.send(data)
        }
    }
}
```

### 3.4 AudioStreamManager (音频流管理)

**职责:**
- 监听音频开始通知
- 建立 TCP 连接接收音频
- 管理音频播放

**实现示例:**
```swift
class AudioStreamManager {
    private var tcpConnection: TCPConnection?
    private var audioPlayer: AudioPlayer?
    
    func startReceiving(port: UInt16) {
        // 建立 TCP 连接
        tcpConnection = TCPConnection(host: "127.0.0.1", port: port)
        tcpConnection?.onData = { [weak self] data in
            self?.handleAudioData(data)
        }
        tcpConnection?.onClosed = { [weak self] in
            self?.onTCPConnectionClosed()
        }
    }
    
    private func handleAudioData(_ data: Data) {
        // 将音频数据发送给播放器
        audioPlayer?.play(data)
    }
    
    func stopReceiving() {
        tcpConnection?.close()
        tcpConnection = nil
    }
}
```

---

## 4. 鉴权流程

### 4.1 完整鉴权流程

```
CXR-L                    Rokid AI
  │                        │
  │ 1.构建 URL Scheme      │
  │────────────────────────│
  │  rokidai://connect?... │
  │                        │
  │ 2. 打开 URL            │
  │───────────────────────►│
  │                        │
  │                        │ 3. 验证参数
  │                        │ 4. 创建 Session
  │                        │
  │ 5.URL Callback         │
  │◄───────────────────────│
  │  success=true&token=xx │
  │                        │
  │ 6. 鉴权成功            │
  │                        │
```

### 4.2 代码实现

```swift
// CXR-L 端发起鉴权
class CXRService {
    private let client = RGCxrClient.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // 监听 Client 状态
        client.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleClientState(state)
            }
            .store(in: &cancellables)
    }
    
    func connectToRokidAI() {
        let scopes = ["device_control", "audio_stream"]
        let callback = "cxrl://auth/callback"
        
        client.authenticate(scopes: scopes, callback: callback)
    }
    
    private func handleClientState(_ state: SessionState) {
        switch state {
        case .notEstablished:
            break
            
        case .established(let token, let sessionId):
            print("Session 建立，token: \(token)")
            
        case .bluetoothConnected:
            print("蓝牙已连接，开始通信")
            startBluetoothCommunication()
            
        case .bluetoothDisconnected:
            print("蓝牙已断开")
            
        case .terminated:
            print("Session 终止")
        }
    }
}
```

### 4.3 处理 URL Callback

```swift
// AppDelegate 中处理 URL
func application(_ app: UIApplication, 
                 open url: URL, 
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    
    // 检查是否是鉴权回调
    if url.scheme == "cxrl" && url.host == "auth" && url.path == "/callback" {
        return RGCxrClient.shared.handleAuthCallback(url: url)
    }
    
    return false
}
```

---

## 5. 蓝牙通信

### 5.1 发送消息

```swift
// 发送控制命令
func sendCommand() {
    RGCxrClient.shared.send(
        cmd: .Ai,
        subCmd: .KeyDown,
        data: nil
    )
}

// 发送带数据的命令
func sendCommandWithData() {
    let data: [String: Any] = [
        "key": "value"
    ]
    
    RGCxrClient.shared.send(
        cmd: .Ai,
        subCmd: .KeyUp,
        data: data
    )
}

// 底层通过 RGCxrClientBLE 发送
// RGCxrClientBLE 会将消息编码为二进制协议并通过 BLE 发送
```

### 5.2 接收消息

**RGCxrClientBLE 内部处理:**

```swift
// RGCxrClientBLE 通过 CBPeripheralDelegate 接收 BLE 数据
func peripheral(_ peripheral: CBPeripheral,
                didUpdateValueFor characteristic: CBCharacteristic,
                error: Error?) {
    if let data = characteristic.value {
        // 解码二进制协议
        let response = decode(data: data)
        
        // 通过 Subject 发送给上层
        dataSubject.send(response)
    }
}

// 上层通过 Combine 监听
RGCxrClient.shared.ble.rawData
    .sink { data in
        // 处理接收到的数据
    }
    .store(in: &cancellables)
```

**使用示例:**

```swift
// 方式一：通过 Combine
RGCxrClient.shared.dataPublisher
    .receive(on: DispatchQueue.main)
    .sink { response in
        switch response.enumSubCmd {
        case .Ai_Heartbeat:
            handleHeartbeat()
        case .Ai_StartAudioStream:
            handleStartAudioStream(response)
        default:
            break
        }
    }
    .store(in: &cancellables)

// 方式二：通过 Delegate
class MessageHandler: RGCxrClientDelegate {
    func onCommand(_ response: RGCxrDataResponse) {
        // 处理命令响应
    }
    
    func onNotify(_ response: RGCxrDataResponse) {
        // 处理通知
    }
}

RGCxrClient.shared.delegate = MessageHandler()
```

---

## 6. 音频接收

### 6.1 音频接收流程

```
Rokid AI              CXR-L
   │                    │
   │ 1.开启拾音         │
   │                    │
   │ 2.启动 TCP Server  │
   │                    │
   │ 3. 通知 TCP 端口     │
   │───────────────────►│
   │  (通过蓝牙)         │
   │                    │
   │                    │ 4.建立 TCP 连接
   │◄───────────────────│
   │                    │
   │ 5. 音频流传输       │
   │───────────────────►│
   │  (TCP)             │
   │                    │
   │ 6. 心跳保活         │
   │───────────────────►│
   │  (通过蓝牙)         │
   │                    │
```

### 6.2 代码实现

```swift
class AudioStreamManager {
    private var tcpConnection: TCPConnection?
    private var audioPlayer: AVAudioPlayer?
    private var heartbeatTimer: Timer?
    
    // 处理音频开始通知
    func handleStartAudioStream(_ response: RGCxrDataResponse) {
        guard let args = response.responseData as? [String: Any],
              let port = args["tcpPort"] as? UInt16 else {
            return
        }
        
        // 建立 TCP 连接
        startReceiving(port: port)
        
        // 启动心跳检测
        startHeartbeatCheck()
    }
    
    private func startReceiving(port: UInt16) {
        tcpConnection = TCPConnection(host: "127.0.0.1", port: port)
        
        tcpConnection?.onData = { [weak self] data in
            self?.handleAudioData(data)
        }
        
        tcpConnection?.onClosed = { [weak self] in
            self?.stopReceiving()
        }
    }
    
    private func handleAudioData(_ data: Data) {
        // 解码并播放音频
        audioPlayer?.play(data)
    }
    
    private func startHeartbeatCheck() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkHeartbeat()
        }
    }
    
    private func checkHeartbeat() {
        // 检查是否收到心跳
        // 如果超时，停止音频接收
    }
    
    func stopReceiving() {
        tcpConnection?.close()
        tcpConnection = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}
```

---

## 7. 错误处理

### 7.1 错误类型

```swift
enum RGCxrClientError: LocalizedError {
    // 鉴权错误
    case authFailed(String)
    case authExpired
    case invalidCallback
    
    // 连接错误
    case bluetoothDisconnected
    case tcpConnectionFailed
    
    // 音频错误
    case audioStreamFailed
    case heartbeatTimeout
    
    public var errorDescription: String? {
        switch self {
        case .authFailed(let message):
            return "鉴权失败：\(message)"
        case .authExpired:
            return "鉴权已过期"
        case .bluetoothDisconnected:
            return "蓝牙已断开"
        case .tcpConnectionFailed:
            return "TCP 连接失败"
        case .audioStreamFailed:
            return "音频流失败"
        case .heartbeatTimeout:
            return "心跳超时"
        default:
            return "未知错误"
        }
    }
}
```

### 7.2 错误恢复

```swift
class ErrorHandler {
    private var reconnectAttempts = 0
    private let maxAttempts = 5
    private let delays = [1, 2, 4, 8, 16]
    
    func handleError(_ error: Error) {
        guard let clientError = error as? RGCxrClientError else {
            return
        }
        
        switch clientError {
        case .bluetoothDisconnected:
            scheduleReconnect()
            
        case .heartbeatTimeout:
            stopAudioStreaming()
            
        case .authExpired:
            restartAuth()
            
        default:
            break
        }
    }
    
    private func scheduleReconnect() {
        guard reconnectAttempts < maxAttempts else {
            onMaxRetriesReached()
            return
        }
        
        let delay = delays[min(reconnectAttempts, delays.count - 1)]
        reconnectAttempts += 1
        
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) {
            self.reconnect()
        }
    }
    
    private func reconnect() {
        RGCxrKit.shared.reconnect()
    }
    
    private func restartAuth() {
        // 重新发起鉴权流程
        RGCxrClient.shared.authenticate(scopes: ["device_control", "audio_stream"])
    }
}
```

---

## 8. API 设计

### 8.1 公开 API

```swift
// 单例访问
let client = RGCxrClient.shared

// 鉴权
func authenticate(scopes: [String], callback: String)

// Session 状态 (Session 是 Client 的内部属性)
var session: Session? { get }
var isSessionEstablished: Bool { get }

// 发送消息 (通过内部的 RGCxrClientBLE)
func send(cmd: RGCxrCmd, subCmd: RGCxrSubCmd, data: Any?)

// 事件监听
var statePublisher: AnyPublisher<SessionState, Never> { get }
var dataPublisher: AnyPublisher<RGCxrDataResponse, Never> { get }

// 设置代理
var delegate: RGCxrClientDelegate? { get set }
```

### 8.2 代理协议

```swift
protocol RGCxrClientDelegate: AnyObject {
    func client(_ client: RGCxrClient, didReceiveCommand response: RGCxrDataResponse)
    func client(_ client: RGCxrClient, didReceiveNotify response: RGCxrDataResponse)
    func clientSessionStateDidChange(_ client: RGCxrClient)
}
```

### 8.3 使用示例

```swift
// 初始化
let client = RGCxrClient.shared

// 设置代理
client.delegate = self

// 监听状态
client.statePublisher
    .receive(on: DispatchQueue.main)
    .sink { state in
        switch state {
        case .established(let token, let sessionId):
            print("鉴权成功，token: \(token)")
            
        case .bluetoothConnected:
            print("蓝牙已连接")
            
        case .bluetoothDisconnected:
            print("蓝牙已断开")
            
        default:
            break
        }
    }
    .store(in: &cancellables)

// 发起连接
client.authenticate(
    scopes: ["device_control", "audio_stream"],
    callback: "cxrl://auth/callback"
)

// 发送消息
client.send(cmd: .Ai, subCmd: .KeyDown, data: nil)

// Delegate 回调
extension CXRService: RGCxrClientDelegate {
    func client(_ client: RGCxrClient, didReceiveCommand response: RGCxrDataResponse) {
        // 处理命令响应
    }
    
    func client(_ client: RGCxrClient, didReceiveNotify response: RGCxrDataResponse) {
        // 处理通知
        switch response.enumSubCmd {
        case .Ai_StartAudioStream:
            handleAudioStream(response)
        default:
            break
        }
    }
    
    func clientSessionStateDidChange(_ client: RGCxrClient) {
        // Session 状态变化
    }
}
```

---

## 附录

### A. Info.plist 配置

```xml
<!-- URL Scheme -->
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

<!-- 查询 Rokid AI URL Scheme -->
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>rokidai</string>
</array>

<!-- 后台蓝牙模式 -->
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
</array>
```

### B. 参考资料

- [主架构文档](./README.md)
- [RGCxrProtocol.swift](./RGCxrCore/Classes/RGCxrProtocol.swift)
- [RGCxrKit.swift](./RGCxrKit/Classes/Public/RGCxrKit.swift)

---

## 附录 C: RGCxrClientBLE 实现细节

### C.1 UUID 定义

```swift
enum RGCxrUUID: String {
    case service = "9100"
    case write = "9201"
    case read = "9202"
    
    var uuid: CBUUID {
        CBUUID(string: self.rawValue)
    }
}
```

### C.2 协议编解码

```swift
// 二进制协议格式参考 RGCxrProtocol.swift
// RGCxrClientBLE 需要实现相同的编解码逻辑

struct BinaryProtocol {
    static func encode(cmd: String, subCmd: String, data: Data?) -> Data {
        // 编码为二进制格式
        var buffer = Data()
        // Magic + Version + ReqID + CmdLen + Cmd + ArgsLen + Args + DataLen + Data
        return buffer
    }
    
    static func decode(_ data: Data) -> (cmd: String, subCmd: String, args: Data?)? {
        // 从二进制数据解码
        return nil
    }
}
```

### C.3 错误处理

```swift
enum RGCxrClientBLEError: LocalizedError {
    case bluetoothUnavailable
    case scanTimeout
    case connectionFailed
    case serviceNotFound
    case characteristicNotFound
    case writeFailed
    
    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "蓝牙不可用"
        case .scanTimeout:
            return "扫描超时"
        case .connectionFailed:
            return "连接失败"
        case .serviceNotFound:
            return "服务未找到"
        case .characteristicNotFound:
            return "特征值未找到"
        case .writeFailed:
            return "写入失败"
        }
    }
}
```

### C.4 重连策略

```swift
class ReconnectionManager {
    private var reconnectAttempts = 0
    private let maxAttempts = 5
    private let delays = [1, 2, 4, 8, 16] // 指数退避
    
    func scheduleReconnect() {
        guard reconnectAttempts < maxAttempts else {
            return
        }
        
        let delay = delays[min(reconnectAttempts, delays.count - 1)]
        reconnectAttempts += 1
        
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) {
            self.reconnect()
        }
    }
    
    func reset() {
        reconnectAttempts = 0
    }
}
```

### C.5 与 RGCxrKit 的对比

| 特性 | RGCxrKit (Rokid AI) | RGCxrClientBLE (CXR-L) |
|------|---------------------|------------------------|
| 用途 | Rokid AI 端 | CXR-L 端 |
| 配对逻辑 | ✓ 完整支持 | ✗ 不需要 |
| MFi 支持 | ✓ 支持 | ✗ 仅 BLE |
| 重连逻辑 | ✓ 复杂策略 | ✓ 简单重连 |
| 音频采集 | ✓ 支持 | ✗ 不支持 |
| 协议编解码 | ✓ | ✓ |
| 代码量 | ~3000 行 | ~500 行 |
| 依赖 | 无 | RGCoreKit |
| 复杂度 | 高 | 低 |
