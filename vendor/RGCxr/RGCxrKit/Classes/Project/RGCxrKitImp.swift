//
//  RGCxrKit.swift
//  RokidAIGlasses
//
//  Created by Ginger on 2025/2/27.
//

import Foundation
import CoreBluetooth
import RGCoreKit
@_implementationOnly import RGCxrKit_Private
import ExternalAccessory
import Combine

internal enum RGCxrUUID: String {
    case service = "9100"
    case socket = "9300"
    case serialNumber = "9A01"

    case write = "9201"
    case read = "9202"
    case createBoud = "9203"
    case askConnect = "9204"

    var uuid: CBUUID {
        get {
            CBUUID(string: self.rawValue)
        }
    }
}

/// BLE连接上之后后续流程状态
internal enum RGBleDiscoveryStage {
    case none
    case connected
    case servicesDiscovered
    case characteristicsDiscovered
    case descriptorsDiscovered
}

internal class RGCxrKitImp: NSObject {

    internal var centralManager: CBCentralManager?

    internal var connectionDelegates = NSPointerArray.weakObjects()

    internal var centralManagerDelegates = NSPointerArray.weakObjects()

    internal var audioStreamDelegates = NSPointerArray.weakObjects()

    internal var scanDelegates = NSPointerArray.weakObjects()

    internal var dataDelegates = NSPointerArray.weakObjects()

    internal let startAudioStreamSubject = PassthroughSubject<(codec: Int32, type: String, channels: UInt32), Never>()
    internal let audioStreamSubject = PassthroughSubject<(data: Data, timestamp: UInt64), Never>()
    internal let audioStreamFinishSubject = PassthroughSubject<Void, Never>()
    internal let dataNotifySubject = PassthroughSubject<RGCxrDataResponse, Never>()
    internal let streamSubject = PassthroughSubject<RGCxrStreamResponse, Never>()

    internal weak var accountDelegate: RGCxrAccountDelegate?

    // 内部的原始触发 Subject
    private let backgroundTimerTriggerSubject = PassthroughSubject<Void, Never>()

    internal let backgroundTimerSubject = PassthroughSubject<TimeInterval, Never>()

    // 用于管理 Combine 订阅
    private var cancellables = Set<AnyCancellable>()

    // 蓝牙是否开启
    internal var centralManagerState: CBManagerState {
        centralManager?.state ?? .poweredOff
    }
    var connectionStatusSubject = PassthroughSubject<Bool, Never>()

    /// 原始数据 Publisher（从设备读取的原始数据，在协议解析之前）
    var rawDataSubject = PassthroughSubject<Data, Never>()

    // 已发现的设备
    internal var foundPeripherals: [RGCxrPeripheral] = []

    // 是否通过外部接口发起了扫描
    internal var isScanning = false

    // 扫描用于连接的设备ID
    internal var scanningWaitingSerialNumber: String? {
        didSet {
            RGLog.info(scanningWaitingSerialNumber)
            if scanningWaitingSerialNumber != nil {
                scanTimeoutTimer?.invalidate()
                scanTimeoutTimer = nil
                scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] timer in
                    guard let self = self else { return }
                    RGLog.info(self.connectionStatus.rawValue)
                    if self.scanningWaitingSerialNumber != nil,
                       self.connectionStatus == .bleConnecting {
                        RGLog.info("BLE Reconnecting")
                        self.connectionStatus = .bleReconnecting
                    }
                }
            } else {
                // 扫到了
                scanTimeoutTimer?.invalidate()
                scanTimeoutTimer = nil
            }
        }
    }

    // 添加扫描定时器
    private var scanTimeoutTimer: Timer?

    // 正在尝试连接的设备ID
    internal var connectingSerialNumber: String?

    // 已经连接的设备
    internal var connectedPeripheral: RGCxrPeripheral?

    internal var writeCharacteristic: CBCharacteristic?
    internal var createBoudCharacteristic: CBCharacteristic?

    // 请求管理队列
    internal var requestQueue: RGCxrRequestQueue = RGCxrRequestQueue()

    // 眼镜L2Cap通道数据解析工具
    internal var socketProcotol: RGCxrSocketProtocol?

    // 请求ID
    internal var requestId: Int32 = 0

    // 定义用于读取和发送数据的队列
    internal let readQueue = DispatchQueue(label: "com.rokid.readQueue", qos: .utility)
    internal let sendQueue = DispatchQueue(label: "com.rokid.sendQueue", qos: .utility)

    internal var innerConnectionStatus: RGCxrConnectionStatus = .idle
    // 当前连接状态
    // 连接超时定时器
    private var connectionTimeoutTimer: Timer?

    // BLE服务发现流程超时定时器
    private var bleServiceDiscoveryTimeoutTimer: Timer?

    // 当前BLE服务发现阶段
    private var currentBleDiscoveryStage: RGBleDiscoveryStage = .none

    // 是否在蓝牙状态unknown的时候调用了连接，如果是，要在poweron的时候去尝试连接
    internal var waitingPowerOn: Bool = false
    // 规避错误的mtu
    internal var badMtu: Bool = false

    /// CXR-L 分片重组：F(totalSize,chunkCount) + C(index,binary)...
    internal var fragBuffer: [Int: Data] = [:]
    internal var fragTotalSize: Int = 0
    internal var fragChunkCount: Int = 0
    // 是否是自己主动断开，如果不是，则要尝试重连
    internal var cancelBySelf = false

    // 当前是否暂停重试
    internal var isPauseReconnecting = false

    // 是否是MFI设备
    internal var isMFI = false

    // 眼镜mac地址
    internal var glassesMacAddress: String?

    // 协商获取的眼镜账号
    internal var innerAccount: String?

    // 是否海外版本，protocolString不一样
    internal var isGlobal = false
    // 当前连接的MFI设备及其session
    internal var currentAccessory: EAAccessory?
    internal var currentSession: EASession?
    // MFI发送Data
    internal var outputData = Data()
    // MFI延迟重连任务
    internal var delayedReconnectWorkItem: DispatchWorkItem?
    internal var majorVersion: Int = 0
    internal var minorVersion: Int = 0

    // 用于缓存SerialNumber与name的对应关系，在后台回连的时候使用
    internal var serialMap: [String: String] = [:]

    // 应用是否在前台
    internal var isAppInForeground: Bool = true

    internal var innerMacAddress: String?
    internal var innerBlacklist: [String]?

    internal var connectionStatus: RGCxrConnectionStatus {
        get {
            innerConnectionStatus
        }
        set {
            let old = innerConnectionStatus
            let new = newValue
            RGLog.info("old: \(old) new: \(new)")
            innerConnectionStatus = new
            if new == .idle {
                // 销毁
                verifyResult = (false, false)
                connectedPeripheral = nil
                writeCharacteristic = nil
                createBoudCharacteristic = nil
                badMtu = false
                scanningWaitingSerialNumber = nil
                connectingSerialNumber = nil
                waitingPowerOn = false
                stopTimer()
                stopBleServiceDiscoveryTimeoutTimer()
                currentBleDiscoveryStage = .none
                // MFI处理
                isMFI = false
                closeMFIConnect()
                outputData.removeAll()
                majorVersion = 0
                minorVersion = 0
            } else if new == .bleConnected {
                // 当连接状态变为 bleConnected 时，取消定时器
                stopTimer()
            } else if new == .socketConnected {
                connectingSerialNumber = nil
                isNewPairing = false
            } else if new == .bleConnecting {
                verifyResult.uuid = false
            }
            if old != new {
                // 状态变化时取消MFI延迟重连任务
                delayedReconnectWorkItem?.cancel()
                delayedReconnectWorkItem = nil
                connectionStatusSubject.send(new == .socketConnected)
                connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                    if let delegate = delegate as? RGCxrConnectionDelegate {
//                        RGLog.info("\(String(describing: delegate.debugDescription))")
                        DispatchQueue.main.async {
                            delegate.onConnectionStatusChanged(old: old, new: new)
                        }
                    }
                }
            }
        }
    }

    /// uuid校验结果和account校验结果，同时满足才算连上
    var verifyResult: (uuid: Bool, account: Bool) = (false, false)

    var isSetuped: Bool = false
    /// 初始化SDK
    internal func setup() {
        RGLog.api()
        if isSetuped {
            return
        }
        isSetuped = true
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.rokid.glasses"])
        centralManager?.registerForConnectionEvents(options: [.serviceUUIDs: [RGCxrUUID.service.uuid]])
        socketProcotol = RGCxrSocketProtocol()
        let delegate = RGCxrSocketInternlDelegate()
        socketProcotol?.delegate = delegate
        delegate.cxrKit = self

        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        addMFINotification()

        // 设置 Combine 防抖逻辑
        setupBackgroundTimerDebounce()
    }

    /// 设置 backgroundTimerSubject 的防抖逻辑
    /// 只在应用处于后台时触发，并且有1秒防抖
    private func setupBackgroundTimerDebounce() {
        backgroundTimerTriggerSubject
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .filter { [weak self] _ in
                // 只在后台时通过
                guard let self = self else { return false }
                return !self.isAppInForeground
            }
            .map { _ in
                // 发送当前时间戳
                Date().timeIntervalSince1970
            }
            .sink { [weak self] timestamp in
                guard let self = self else { return }
                self.backgroundTimerSubject.send(timestamp)
            }
            .store(in: &cancellables)
    }

    @objc private func appWillEnterForeground() {
        // 从后台进入前台，UI需展示正在连接
        _ = getServiceRecord(for: serialNumber)
        _ = getMacAddress()
        isAppInForeground = true
        if connectionStatus == .bleReconnecting {
            connectionStatus = .bleConnecting
        }
    }

    @objc private func appDidEnterBackground() {
        // 应用进入后台
        isAppInForeground = false
        sendBackgroundTimerIfNeeded()
    }

    /// 带防抖的 backgroundTimerSubject 发送方法
    /// 只在应用处于后台时发送，并且有1秒防抖（通过 Combine 实现）
    internal func sendBackgroundTimerIfNeeded() {
        // 触发防抖流，filter 会检查是否在后台
        backgroundTimerTriggerSubject.send(())
    }

    @objc private func appWillTerminate() {
        RGLog.info()
        if let connectedPeripheral = connectedPeripheral {
            RGLog.info("cancelPeripheralConnection")
            socketProcotol?.disconnectGATT()
            centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
        }
    }

    internal func startScan() {
        RGLog.api()
        if !isSetuped {
            RGLog.warn("isSetuped is false")
            setup()
        }
        innerScan()
        isScanning = true
        foundPeripherals.removeAll()
    }

    internal func innerScan() {
        RGLog.api()
        let glassesServices = [RGCxrUUID.service.uuid]
        let scanOptions = [CBCentralManagerScanOptionAllowDuplicatesKey: false,
                                CBCentralManagerOptionShowPowerAlertKey: true]
        centralManager?.scanForPeripherals(withServices: glassesServices, options: scanOptions)
    }

    internal func stopScan() {
        RGLog.api()
        centralManager?.stopScan()
        isScanning = false
        foundPeripherals.removeAll()
    }

    // 暂停重连
    internal func pauseReconnecting() {
        RGLog.api()
        isPauseReconnecting = true
    }

    // 恢复重连
    internal func resumeReconnecting() {
        RGLog.api()
        isPauseReconnecting = false
    }

    internal func clearCache() {
        RGLog.api()
        clearKeychain()
    }

    /// 是否是重新配对，如果是重新配对，直接使用眼镜的UUID，如果不是，则要对比UUID
    internal var isNewPairing = false

    /// 当前去连接的或者已经连接的设备序列号
    internal var serialNumber: String?

    /// 配对
    /// - Parameters:
    ///   - serialNumber: 要连接的设备的序列号
    ///   - new: 是否是重新配对
    internal func connect(to serialNumber: String, new: Bool) {
        RGLog.api("serialNumber: \(serialNumber) new: \(new)")

        if !isSetuped {
            RGLog.warn("isSetuped is false")
            setup()
        }

        isNewPairing = new
        self.serialNumber = serialNumber

        if new {
            removeFromBlacklist(serialNumber)
        } else if getBlacklist().contains(serialNumber) {
            RGLog.warn("in blacklist")
            connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrConnectionDelegate {
                    DispatchQueue.main.async {
                        delegate.onConnectionError(.peerRemovePairing)
                    }
                }
            }
            return
        }
        // 有UUID才走回连，不然应该是用户从系统直接连接的，这种情况也要重新去获取UUID
        if let record = getServiceRecord(for: serialNumber),
           !record.isEmpty,
           !new {
            if let mfiDevice = getMFIConnectedAccessories().first(where: { $0.serialNumber == serialNumber }) {
                cancelBySelf = false
                RGLog.info("has mfi device")
                if getAccount(for: serialNumber).isNilOrEmpty || accountDelegate == nil {
                    RGLog.info("innerAccount isNilOrEmpty or accountDelegate is nil")
                    // 没有存的账号或者上层没有实现账号代理
                    if openMFIConnect(mfiDevice) == true {
                        isMFI = true
                        verifyResult.account = true
                        verifyUuid(record)
                        return
                    }
                } else if let account = getAccount(for: serialNumber),
                          let delegate = accountDelegate {
                    // 账号存在，要check一下账号是否被切换了
                    if delegate.onAccountReconnect(account) {
                        if openMFIConnect(mfiDevice) == true {
                            isMFI = true
                            verifyResult.account = true
                            verifyUuid(record)
                            return
                        }
                    } else {
                        RGLog.info()
                        cancelConnect(nil)
                        return
                    }
                }
            }
        }
        resumeReconnecting()
        // 要连接的设备正在内部重连
        if connectionStatus == .bleReconnecting || connectionStatus == .bleConnecting,
           connectingSerialNumber == serialNumber || scanningWaitingSerialNumber == serialNumber {
            RGLog.info("device is connecting")
            connectionStatus = .bleConnecting
            connectingSerialNumber = serialNumber
            reconnectAttempts = 0
            return
        }
        guard connectionStatus == .idle else {
            RGLog.warn("connectionStatus: \(connectionStatus)")
            return
        }
        isMFI = false
        cancelBySelf = false
        connectionStatus = .bleConnecting
        connectingSerialNumber = serialNumber
        if centralManagerState == .poweredOn {
            realConnet(to: serialNumber, resetReconnectAttempts: true)
        } else {
            waitingPowerOn = true
        }
    }

    /// 如果给的是peripheral就直接用，没有再去findPeripheral里找
    internal func realConnet(to serialNumber: String, resetReconnectAttempts: Bool) {
        RGLog.api()
        if resetReconnectAttempts {
            reconnectAttempts = 0
        }
        if centralManagerState == .poweredOn {
            waitingPowerOn = false
            if let peripheral = findPeripheral(by: serialNumber) {
                // 缓存里已经有设备了
                innerConnect(peripheral)
            } else {
                // 缓存里没有设备，先扫描
                innerScan()
                scanningWaitingSerialNumber = serialNumber
            }
        } else {
            connectingSerialNumber = serialNumber
        }
    }

    internal func findPeripheral(by serialNumber: String) -> RGCxrPeripheral? {
        // 优先匹配serialNumber，其次匹配uuid
        foundPeripherals.first(where: { $0.serialNumber == serialNumber })
    }


    // 添加重连计数器
    private var reconnectAttempts = 0 {
        didSet {
            if reconnectAttempts == 0,
               connectionStatus == .bleConnecting || connectionStatus == .bleReconnecting {
                if Thread.isMainThread {
                    startConnectionTimeoutTimer(with: 5)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.startConnectionTimeoutTimer(with: 5)
                    }
                }
            }
        }
    }
    // 5秒一次，总共3次，共尝试重连15秒，5分钟后变成30秒一次
    private let maxReconnectAttempts = 3

    internal func innerConnect(_ peripheral: RGCxrPeripheral) {
        RGLog.api(peripheral.peripheral.debugDescription)
        connectingSerialNumber = peripheral.serialNumber

        // 有UUID才走回连，不然应该是用户从系统直接连接的，这种情况也要重新去获取UUID
        if let record = getServiceRecord(for: connectingSerialNumber),
           !record.isEmpty,
           !isNewPairing {
            if let mfiDevice = getMFIConnectedAccessories().first(where: { $0.serialNumber == connectingSerialNumber }) {
                RGLog.info("has mfi device")
                if openMFIConnect(mfiDevice) == true {
                    // 强制认为账号没问题
                    isMFI = true
                    verifyResult.account = true
                    verifyUuid(record)
                    return
                }
            }
        }

        if centralManager?.state != .poweredOn {
            RGLog.error("not poweredOn")
            return
        }
        if connectionStatus == .bleConnected || connectionStatus == .socketConnected {
            RGLog.error("connected: \(connectionStatus)")
            return
        }
        centralManager?.retrieveConnectedPeripherals(withServices: [RGCxrUUID.service.uuid]).forEach({ p in
            RGLog.info("retrieveConnectedPeripherals \(p.debugDescription)")
        })
        if let manager = centralManager,
           peripheral.peripheral.state == .connected {
            RGLog.info("use restorePeripheral")
            centralManager(manager, didConnect: peripheral.peripheral)
        } else {
            var connectOptions = [CBConnectPeripheralOptionNotifyOnConnectionKey: true]
            if let name = peripheral.peripheral.name,
               !name.hasPrefix("Bolon_") {
//                connectOptions[CBConnectPeripheralOptionRequiresANCS] = true
            }
            centralManager?.connect(peripheral.peripheral, options: connectOptions)
            // 苹果bug，偶现调用connect无任何回调，但是调用两次就恢复
//            DispatchQueue.main.async { [weak self] in
//                self?.centralManager?.connect(peripheral.peripheral, options: connectOptions)
//            }
        }
    }

    private func startConnectionTimeoutTimer(with timeInterval: TimeInterval) {
        RGLog.api()
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            guard !isPauseReconnecting else {
                RGLog.info("paused reconnecting")
                return
            }
            RGLog.info(self.connectionStatus)
            if self.connectionStatus == .bleConnecting || self.connectionStatus == .bleReconnecting {
                self.reconnectAttempts += 1
                if let serialNumber = connectingSerialNumber {
                    foundPeripherals.removeAll(where: { $0.serialNumber == serialNumber })
                    realConnet(to: serialNumber, resetReconnectAttempts: false)
                } else {
                    RGLog.error("no serialNumber")
                }
                if self.reconnectAttempts < self.maxReconnectAttempts {
                    RGLog.warn("Connection timed out. Reconnecting... Attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts)")
                } else {
                    RGLog.error("Max reconnect attempts reached. Attempt \(self.reconnectAttempts)")
                    if connectionStatus == .idle || connectionStatus == .bleConnecting {
                        RGLog.info("BLE Reconnecting")
                        connectionStatus = .bleReconnecting
                    }
                    // 五分钟后重启定时器，且变为30秒一次
                    if self.reconnectAttempts == 60 {
                        DispatchQueue.main.async { [weak self] in
                            self?.startConnectionTimeoutTimer(with: 30)
                        }
                    }
                }
            } else if self.connectionStatus == .bleConnected || self.connectionStatus == .socketConnected {
                timer.invalidate()
                self.connectionTimeoutTimer = nil
            }
        }
    }

    private func stopTimer() {
        RGLog.api()
        DispatchQueue.main.async { [weak self] in
            self?.connectionTimeoutTimer?.invalidate()
            self?.connectionTimeoutTimer = nil
        }
    }

    // MARK: - BLE服务发现超时处理

    internal func startBleServiceDiscoveryTimeoutTimer() {
        RGLog.api("stage: \(currentBleDiscoveryStage)")
        stopBleServiceDiscoveryTimeoutTimer()

        bleServiceDiscoveryTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            RGLog.error("BLE service discovery timeout at stage: \(self.currentBleDiscoveryStage)")
            self.handleBleServiceDiscoveryTimeout()
        }
    }

    internal func stopBleServiceDiscoveryTimeoutTimer() {
        RGLog.api()
        if Thread.isMainThread {
            bleServiceDiscoveryTimeoutTimer?.invalidate()
            bleServiceDiscoveryTimeoutTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.bleServiceDiscoveryTimeoutTimer?.invalidate()
                self?.bleServiceDiscoveryTimeoutTimer = nil
            }
        }
    }

    internal func handleBleServiceDiscoveryTimeout() {
        RGLog.error("BLE service discovery timeout, disconnecting and retrying")
        stopBleServiceDiscoveryTimeoutTimer()
        currentBleDiscoveryStage = .none
        guard !isPauseReconnecting else {
            RGLog.info("paused reconnecting")
            return
        }
        if let connectedPeripheral = connectedPeripheral {
            if let record = getServiceRecord(for: connectedPeripheral.serialNumber),
               !record.isEmpty,
               let mfiDevice = getMFIConnectedAccessories().first(where: { $0.serialNumber == connectedPeripheral.serialNumber }),
               openMFIConnect(mfiDevice) == true {
                RGLog.info("has mfi device")
                // 强制认为账号没问题
                isMFI = true
                verifyResult.account = true
                verifyUuid(record)
            } else {
                // 断开连接并触发重新配对流程
                cancelBySelf = false // 标记为非主动断开，需要重试
                isMFI = false
                centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
            }
        }
    }

    internal func updateBleDiscoveryStage(_ stage: RGBleDiscoveryStage) {
        RGLog.api("from \(currentBleDiscoveryStage) to \(stage)")
        currentBleDiscoveryStage = stage

        // 如果到达最终阶段，停止超时定时器
        if stage == .descriptorsDiscovered {
            if Thread.isMainThread {
                stopBleServiceDiscoveryTimeoutTimer()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.stopBleServiceDiscoveryTimeoutTimer()
                }
            }
        } else {
            // 为下一个阶段启动超时定时器
            if Thread.isMainThread {
                startBleServiceDiscoveryTimeoutTimer()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.startBleServiceDiscoveryTimeoutTimer()
                }
            }
        }
    }

    internal var lastCancelId: String?
    internal var cancelCallback: (() -> Void)?
    internal func cancelConnect(_ callback: (() -> Void)?) {
        RGLog.api()
        resetFragState()
        if let _ = scanningWaitingSerialNumber,
           !isScanning {
            stopScan()
        }
        socketProcotol?.disconnectGATT()
        if isMFI {
            closeMFIConnect()
        }
        if let connectedPeripheral = connectedPeripheral {
            RGLog.info("connected")
            lastCancelId = connectedPeripheral.peripheral.identifier.uuidString
            connectionStatus = .idle
            cancelBySelf = true
            cancelCallback = callback
            // 延时一下，确保disconnectGATT完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
            }
        } else if let serialNumber = connectingSerialNumber,
                  let peripheral = findPeripheral(by: serialNumber)?.peripheral {
            RGLog.info("connecting")
            lastCancelId = peripheral.identifier.uuidString
            connectionStatus = .idle
            cancelBySelf = true
            cancelCallback = callback
            // 延时一下，确保disconnectGATT完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.centralManager?.cancelPeripheralConnection(peripheral)
            }
        } else {
            RGLog.info("other case")
            connectionStatus = .idle
            DispatchQueue.main.async {
                callback?()
            }
        }
    }

    // 发送蓝牙数据
    internal func sendData(cmd: String, subCmd: String? = nil, data: Any?, onResponse: ((RGCxrBaseResponse) -> Void)?) {
        requestId += 1
        let id = requestId
        if subCmd == RGCxrSubCmd.Sys_sendContacts.rawValue {
            RGLog.api("start: \(cmd) | data: *** | requestId: \(id)")
        } else if cmd == RGCxrCmd.Pay.rawValue {
            RGLog.debug("start: \(cmd) | subCmd: \(subCmd ?? "") | requestId: \(id)")
        } else {
            RGLog.api("start: \(cmd) | data: \(data ?? "") | requestId: \(id)")
        }
        guard connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus: \(connectionStatus)")
            onResponse?(RGCxrErrorResponse(errorCode: -1, errorMsg: "l2Cap error"))
            return
        }
        if !isMFI {
            guard let _ = connectedPeripheral else {
                RGLog.error("connectedPeripheral is empty")
                onResponse?(RGCxrErrorResponse(errorCode: -1, errorMsg: "connectedPeripheral is empty"))
                return
            }
        }
        let subCaps = RCaps()
        if let data = data {
            writeDataToCaps(subCaps, data: data)
        }
        socketProcotol?.request(withReqId: Int(id), cmd: cmd, args: subCaps)
        if let onResponse = onResponse {
            let request = RGCxrRequestModel(reqId: requestId,
                                            requestTime: Date().timeIntervalSince1970,
                                            cmd: cmd,
                                            onResponse: onResponse)
            requestQueue.addModel(request)
        }
    }

    /// 开启眼镜的音频采集
    /// - Parameter type: 采集类型，会在onStartAudioStream回调中返回
    internal func openAudioRecord(type: String, codec: RGCxrAudioCodec, mode: RGCxrAudioMode, denoiseMode: Int32 = -1, rokidDtlnAEC: Bool = false, rokidBF: Bool = false) {
        RGLog.api([
            "type": type,
            "codec": "\(codec)",
            "mode": "\(mode)",
            "denoiseMode": denoiseMode,
            "rokidDtlnAEC": rokidDtlnAEC,
            "rokidBF": rokidBF
        ])
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        socketProcotol?.openAudioRecord(withCodec: codec.rawValue, mode: mode.rawValue, intent: type, denoiseMode: denoiseMode, rokidDtlnAEC: rokidDtlnAEC, rokidBF: rokidBF)
    }

    /// 关闭眼镜音频
    internal func closeAudioRecord(type: String) {
        RGLog.api(type)
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        socketProcotol?.closeAudioRecord(withCmd: type)
    }

    internal func startPlayAudio(streamId: UInt32, prio: Int32, speed: Float, codec: RGCxrAudioCodec) {
        RGLog.api(streamId)
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        socketProcotol?.startPlayAudio(withId: streamId, prio: prio, speed: speed, codec: codec.rawValue)
    }

    internal func sendAudioStream(streamId: Int, data: Data) {
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        socketProcotol?.sendAudioStream(withId: streamId, data: data)
    }

    internal func cancelAudioPlay(streamId: Int) {
        RGLog.api(streamId)
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        socketProcotol?.cancelAudioPlay(withId: streamId)
    }

    internal func finishAudioStream(streamId: Int) {
        RGLog.api(streamId)
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        socketProcotol?.finishAudioStream(withId: streamId)
    }

    // sock-proto里是多线程使用的，防止释放，会一直占用最用一次发送的内存，但是不大，正常要从socketProcotol回调出来释放
    var streamData: Data?
    /// 发送数据给眼镜
    /// - Parameters:
    ///   - cmd: cmd
    ///   - subCmd: subCmd
    ///   - args: 参数
    ///   - data: 数据
    internal func sendStream(cmd: String, subCmd: String, args: Any?, data: Data) {
        RGLog.api([
            "cmd": cmd,
            "subCmd": subCmd,
            "length": data.count
        ])
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        var requestData: [Any] = [subCmd]
        if let args = args {
            requestData.append(args)
        }
        let subCaps = RCaps()
        writeDataToCaps(subCaps, data: requestData)
        streamData = data
        socketProcotol?.sendStream(withCmd: cmd, args: subCaps, stream: data)
    }

    internal func sendStream(cmd: String, args: Any?, data: Data) {
        RGLog.api([
            "cmd": cmd,
            "length": data.count
        ])
        if connectionStatus != .socketConnected {
            RGLog.error("connectionStatus: \(connectionStatus)")
            return
        }
        let caps = RCaps()
        if let args = args {
            writeDataToCaps(caps, data: args)
        }
        streamData = data
        socketProcotol?.sendStream(withCmd: cmd, args: caps, stream: data)
    }
}

// delegates
extension RGCxrKitImp {

    internal func addConnectionDelegate(_ delegate: RGCxrConnectionDelegate) {
//        RGLog.api("\(String(describing: delegate.debugDescription))")
        connectionDelegates.addWeakObject(delegate)
    }

    internal func removeConnectionDelegate(_ delegate: RGCxrConnectionDelegate) {
//        RGLog.api("\(String(describing: delegate.debugDescription))")
        connectionDelegates.removeWeakObject(delegate)
    }

    internal func addScanDelegate(_ delegate: RGCxrScanDelegate) {
        scanDelegates.addWeakObject(delegate)
    }

    internal func removeScanDelegate(_ delegate: RGCxrScanDelegate) {
        scanDelegates.removeWeakObject(delegate)
    }

    internal func addDataDelegate(_ delegate: RGCxrDataDelegate) {
        dataDelegates.addWeakObject(delegate)
    }

    internal func removeDataDelegate(_ delegate: RGCxrDataDelegate) {
        dataDelegates.removeWeakObject(delegate)
    }

    internal func addCentralManagerDelegate(_ delegate: RGCxrCentralManagerDelegate) {
        centralManagerDelegates.addWeakObject(delegate)
    }

    internal func removeCentralManagerDelegate(_ delegate: RGCxrCentralManagerDelegate) {
        centralManagerDelegates.removeWeakObject(delegate)
    }

    internal func addAudioStreamDelegate(_ delegate: RGCxrAudioStreamDelegate) {
        audioStreamDelegates.addWeakObject(delegate)
    }

    internal func removeAudioStreamDelegate(_ delegate: RGCxrAudioStreamDelegate) {
        audioStreamDelegates.removeWeakObject(delegate)
    }
}
