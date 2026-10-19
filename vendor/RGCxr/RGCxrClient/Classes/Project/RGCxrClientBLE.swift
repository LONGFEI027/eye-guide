//
//  RGCxrClientBLE.swift
//  RGCxrClient
//
//  Created by Ginger on 2026/2/28.
//

import Foundation
import CoreBluetooth
import Combine
import RGCoreKit
@_implementationOnly import RGCxrClient_Private

internal enum RGCxrClientUUID: String {
    case service = "9400"
    case read = "9403"
    case write = "9402"

    var uuid: CBUUID {
        CBUUID(string: rawValue)
    }
}

public final class RGCxrClientBLE: NSObject {

    public static let shared = RGCxrClientBLE()
    
    internal var timer: Timer?
    
    private var _reqId = 0
    var reqId: Int {
        _reqId += 1
        return _reqId
    }

    public private(set) var isConnected = false
    public private(set) var connectedDeviceName: String?

    private let connectionStateSubject = CurrentValueSubject<Bool, Never>(false)
    private let notifySubject = PassthroughSubject<String, Never>()
    private let encodedDataSubject = PassthroughSubject<Data, Never>()

    public var connectionStatePublisher: AnyPublisher<Bool, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    public var notifyPublisher: AnyPublisher<String, Never> {
        notifySubject.eraseToAnyPublisher()
    }

    public var encodedDataPublisher: AnyPublisher<Data, Never> {
        encodedDataSubject.eraseToAnyPublisher()
    }

    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var targetDeviceName: String?
    private var isManualDisconnectRequested = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var incomingBuffer = Data()
    private let maxIncomingBufferSize = 2 * 1024 * 1024
    private let reconnectBaseDelay: TimeInterval = 5.0
    private let reconnectMaxDelay: TimeInterval = 30.0
    private var isNotifyReady = false
    private var isWriteReady = false
    /// 分片协商头 subCmd，单字符控制在 ~15 字节内以适配 MTU 20
    private static let fragHeaderSubCmd = "F"
    private static let fragChunkSubCmd = "C"

    private var writeQueue: [Data] = []
    private var pendingChunks: [Data] = []
    private var writeInFlight = false
    private var writeAckTimeoutWorkItem: DispatchWorkItem?
    private let writeAckTimeout: TimeInterval = 3.0
    private let maxPendingWriteCount = 32

    public override init() {
        super.init()
        RGLog.info("[RGCxrClientBLE] init, target service: \(RGCxrClientUUID.service.rawValue)")
    }

    internal func connect(name: String) {
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            RGLog.error("[RGCxrClientBLE] connect failed: empty device name")
            return
        }
        
        isManualDisconnectRequested = false
        resetReconnectBackoff()
        cancelReconnectSchedule()
        
        if isConnected {
            if connectedDeviceName == targetName {
                RGLog.info("[RGCxrClientBLE] already connected to target device: \(targetName)")
                return
            } else {
                RGLog.info("[RGCxrClientBLE] disconnecting current device: \(connectedDeviceName ?? "nil"), connecting to new device: \(targetName)")
                disconnect()
            }
        }
        
        targetDeviceName = targetName
        RGLog.info("[RGCxrClientBLE] connect requested, central state: \(centralManager.state.rawValue)")
        RGLog.info("[RGCxrClientBLE] target device name: \(targetName)")
        if centralManager.state == .poweredOn {
            tryReconnectOrScan(trigger: "connect")
        } else {
            RGLog.warn("[RGCxrClientBLE] central not poweredOn, waiting callback")
        }
    }

    internal func disconnect() {
        RGLog.info("[RGCxrClientBLE] disconnect requested")
        isManualDisconnectRequested = true
        cancelReconnectSchedule()
        resetReconnectBackoff()
        resetGattSessionState(clearQueuedWrites: true)
        if let peripheral {
            RGLog.info("[RGCxrClientBLE] cancel connection: \(peripheral.identifier.uuidString)")
            centralManager.cancelPeripheralConnection(peripheral)
        }
        incomingBuffer.removeAll(keepingCapacity: true)
        targetDeviceName = nil
        connectedDeviceName = nil
        updateConnectionState(false)
    }
    
    /// 字符串版本，支持扩展字段（用于附带 token 等鉴权信息）。
    public func send(data: Any?, dataExt: Any?) {
        let cmd = RGCxrCmd.Sys.rawValue
        let subCmd = RGCxrSubCmd.Sys_Bt_Gatt_Msg.rawValue
        RGLog.info("[RGCxrClientBLE] send notify cmd: \(cmd), subCmd: \(subCmd), hasData: \(data != nil)")
        let argsCaps = RCaps()
        var payload: [Any] = [subCmd]
        if let data {
            payload.append(data)
        }
        if let dataExt {
            payload.append(dataExt)
        }
        writeDataToCaps(argsCaps, data: payload)
        if let data = argsCaps.serialize() {
            sendRawData(data)
        }
    }

    /// 外部可直接喂入收到的数据，便于脱离 BLE 的单元测试。
    public func handleIncomingData(_ data: Data) {
        guard !data.isEmpty else { return }
//        RGLog.debug("[RGCxrClientBLE] incoming BLE data size: \(data.count)")
        incomingBuffer.append(data)
        if incomingBuffer.count > maxIncomingBufferSize {
            RGLog.error("[RGCxrClientBLE] incoming buffer overflow: \(incomingBuffer.count), clear buffer")
            incomingBuffer.removeAll(keepingCapacity: true)
            return
        }
        processIncomingBuffer()
    }

    public func sendRawData(_ data: Data) {
        guard !data.isEmpty else { return }
        RGLog.debug("[RGCxrClientBLE] sendRawData size: \(data.count)")
        encodedDataSubject.send(data)
        enqueueWrite(data)
    }

    private func startScan() {
        RGLog.info("[RGCxrClientBLE] start scan service: \(RGCxrClientUUID.service.rawValue)")
        centralManager.stopScan()
        centralManager.scanForPeripherals(withServices: [RGCxrClientUUID.service.uuid], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }
    
    private func handleConnectedPeripheral(_ peripheral: CBPeripheral, trigger: String) {
        RGLog.info("[RGCxrClientBLE] handle connected peripheral id: \(peripheral.identifier.uuidString), trigger: \(trigger)")
        self.peripheral = peripheral
        resetGattSessionState(clearQueuedWrites: false)
        isManualDisconnectRequested = false
        cancelReconnectSchedule()
        resetReconnectBackoff()
        connectedDeviceName = peripheral.name
        peripheral.delegate = self
        peripheral.discoverServices([RGCxrClientUUID.service.uuid])
        updateConnectionState(true)
    }
    
    private func tryReconnectOrScan(trigger: String) {
        guard centralManager.state == .poweredOn else {
            RGLog.warn("[RGCxrClientBLE] skip reconnectOrScan: central not poweredOn, trigger: \(trigger)")
            return
        }
        guard let targetDeviceName, !targetDeviceName.isEmpty else {
            RGLog.warn("[RGCxrClientBLE] skip reconnectOrScan: target name empty, trigger: \(trigger)")
            return
        }
        
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [RGCxrClientUUID.service.uuid])
        if let matchedPeripheral = connectedPeripherals.first(where: { $0.name == targetDeviceName }) {
            RGLog.info("[RGCxrClientBLE] retrieveConnected hit, id: \(matchedPeripheral.identifier.uuidString), state: \(matchedPeripheral.state.rawValue), trigger: \(trigger)")
            centralManager.stopScan()
            peripheral = matchedPeripheral
            matchedPeripheral.delegate = self
            // 系统侧已连接时也必须对当前 central 调用 connect，才会稳定收到 didConnect，
            // 并与本 app 的 GATT 会话对齐；若仅直接 discoverServices，往往没有 didConnect，易误判为「无连接回调」。
            let connectOptions = [CBConnectPeripheralOptionNotifyOnConnectionKey: true]
            centralManager.connect(matchedPeripheral, options: connectOptions)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.connectedDeviceName == nil {
                    self?.centralManager.connect(matchedPeripheral, options: connectOptions)
                }
            }
            return
        }
        
        RGLog.info("[RGCxrClientBLE] retrieveConnected miss, fallback scan, trigger: \(trigger)")
        startScan()
    }

    private func updateConnectionState(_ connected: Bool) {
        if isConnected != connected {
            RGLog.info("[RGCxrClientBLE] connection state -> \(connected ? "connected" : "disconnected")")
        }
        isConnected = connected
        connectionStateSubject.send(connected)
    }
    
    private func scheduleReconnectIfNeeded(reason: String) {
        guard !isManualDisconnectRequested else {
            RGLog.info("[RGCxrClientBLE] skip reconnect: manual disconnect")
            return
        }
        guard let targetDeviceName, !targetDeviceName.isEmpty else {
            RGLog.info("[RGCxrClientBLE] skip reconnect: target device name is empty")
            return
        }
        guard centralManager.state == .poweredOn else {
            RGLog.warn("[RGCxrClientBLE] skip reconnect scheduling: central not poweredOn")
            return
        }
        
        cancelReconnectSchedule()
        let delay = min(reconnectBaseDelay * pow(2.0, Double(reconnectAttempt)), reconnectMaxDelay)
        reconnectAttempt += 1
        RGLog.warn("[RGCxrClientBLE] schedule reconnect #\(reconnectAttempt), delay: \(delay)s, reason: \(reason)")
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isConnected else {
                self.resetReconnectBackoff()
                return
            }
            guard !self.isManualDisconnectRequested else { return }
            RGLog.info("[RGCxrClientBLE] reconnect now, target: \(targetDeviceName)")
            self.tryReconnectOrScan(trigger: "scheduleReconnectIfNeeded")
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    private func cancelReconnectSchedule() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }
    
    private func resetReconnectBackoff() {
        reconnectAttempt = 0
    }
    
    private var isGattReady: Bool {
        isConnected && isWriteReady && isNotifyReady
    }
    
    private func resetGattSessionState(clearQueuedWrites: Bool) {
        isNotifyReady = false
        isWriteReady = false
        writeInFlight = false
        cancelWriteAckTimeout()
        if clearQueuedWrites {
            writeQueue.removeAll(keepingCapacity: true)
            pendingChunks.removeAll(keepingCapacity: true)
        }
    }
    
    /// 构建分片包：F(totalSize,chunkCount) + C(0,bin) + C(1,bin) + ...
    private func buildFragmentedPackets(payload: Data, maxLen: Int) -> [Data] {
        let chunkPayloadMax = max(1, maxLen - 14)
        let chunkCount = (payload.count + chunkPayloadMax - 1) / chunkPayloadMax
        let headerCaps = RCaps()
        headerCaps.write_String(Self.fragHeaderSubCmd)
        headerCaps.write_Int32(Int32(payload.count))
        headerCaps.write_Int32(Int32(chunkCount))
        guard let headerData = headerCaps.serialize(), headerData.count <= maxLen else {
            return []
        }
        var packets: [Data] = [headerData]
        var offset = 0
        for i in 0..<chunkCount {
            let end = min(offset + chunkPayloadMax, payload.count)
            let chunkData = Data(payload[offset..<end])
            offset = end
            let chunkCaps = RCaps()
            chunkCaps.write_String(Self.fragChunkSubCmd)
            chunkCaps.write_Int32(Int32(i))
            chunkCaps.write_Binary(chunkData)
            guard let ser = chunkCaps.serialize(), ser.count <= maxLen else {
                return []
            }
            packets.append(ser)
        }
        return packets
    }

    private func enqueueWrite(_ data: Data) {
        if writeQueue.count >= maxPendingWriteCount {
            RGLog.error("[RGCxrClientBLE] write queue overflow, drop data. size: \(data.count)")
            return
        }
        writeQueue.append(data)
        flushWriteQueueIfPossible(trigger: "enqueueWrite")
    }
    
    private func flushWriteQueueIfPossible(trigger: String) {
        guard let peripheral, let writeCharacteristic else {
            RGLog.warn("[RGCxrClientBLE] skip flush queue: write characteristic not ready, trigger: \(trigger)")
            return
        }
        guard isGattReady else {
            RGLog.debug("[RGCxrClientBLE] skip flush queue: gatt not ready, connected: \(isConnected), notify: \(isNotifyReady), write: \(isWriteReady), trigger: \(trigger)")
            return
        }
        guard !writeInFlight else {
            RGLog.debug("[RGCxrClientBLE] skip flush queue: write in flight, trigger: \(trigger)")
            return
        }

        let withResp = peripheral.maximumWriteValueLength(for: .withResponse)
        let withoutResp = peripheral.maximumWriteValueLength(for: .withoutResponse)
        // 当 bearer 切换（如 ANCS 触发）时 withResponse 可能仍返回 512，但实际 MTU 已降为 23（withoutResponse=20）
        let maxLen = min(withResp, max(withoutResp, 20))
        guard maxLen > 0 else {
            RGLog.error("[RGCxrClientBLE] invalid maxWriteLen: \(maxLen), skip flush")
            return
        }

        if !pendingChunks.isEmpty {
            let chunk = pendingChunks.removeFirst()
            writeInFlight = true
            scheduleWriteAckTimeout(payloadSize: chunk.count)
            RGLog.debug("[RGCxrClientBLE] BLE write chunk size: \(chunk.count), remaining: \(pendingChunks.count), trigger: \(trigger)")
            peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
            return
        }

        guard !writeQueue.isEmpty else { return }

        let next = writeQueue.removeFirst()
        if next.count > maxLen {
            // 协商头协议：先发 F(totalSize,chunkCount)，再发 C(index,binary)... CXRKit 组包
            let fragPackets = buildFragmentedPackets(payload: next, maxLen: maxLen)
            if fragPackets.isEmpty {
                RGLog.error("[RGCxrClientBLE] frag packets build failed, drop. size: \(next.count)")
                flushWriteQueueIfPossible(trigger: "fragBuildFailed")
                return
            }
            pendingChunks = fragPackets
            RGLog.debug("[RGCxrClientBLE] frag header+\(pendingChunks.count - 1) chunks, total: \(next.count), max: \(maxLen)")
        } else {
            pendingChunks = [next]
        }

        let chunk = pendingChunks.removeFirst()
        writeInFlight = true
        scheduleWriteAckTimeout(payloadSize: chunk.count)
        RGLog.debug("[RGCxrClientBLE] BLE write size: \(chunk.count), chunks: \(pendingChunks.count + 1), trigger: \(trigger)")
        peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
    }
    
    private func scheduleWriteAckTimeout(payloadSize: Int) {
        cancelWriteAckTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.writeInFlight else { return }
            RGLog.error("[RGCxrClientBLE] write ack timeout, payload: \(payloadSize), disconnect to recover")
            self.writeInFlight = false
            self.writeQueue.removeAll(keepingCapacity: true)
            self.pendingChunks.removeAll(keepingCapacity: true)
            if let peripheral = self.peripheral {
//                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        writeAckTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + writeAckTimeout, execute: workItem)
    }
    
    private func cancelWriteAckTimeout() {
        writeAckTimeoutWorkItem?.cancel()
        writeAckTimeoutWorkItem = nil
    }

    private func writeDataToCaps(_ caps: RCaps, data: Any) {
        if let dataList = data as? [Any] {
            dataList.forEach { writeDataToCaps(caps, data: $0) }
            return
        }
        if let value = data as? String {
            caps.write_String(value)
        } else if let value = data as? Int32 {
            caps.write_Int32(value)
        } else if let value = data as? UInt32 {
            caps.write_UInt32(value)
        } else if let value = data as? Int64 {
            caps.write_Int64(value)
        } else if let value = data as? UInt64 {
            caps.write_UInt64(value)
        } else if let value = data as? Float {
            caps.write_Float(value)
        } else if let value = data as? Double {
            caps.write_Double(value)
        } else if let value = data as? Data {
            caps.write_Binary(value)
        }
    }
    
    private func processIncomingBuffer() {
        var consumedTotal = 0
        
        while consumedTotal < incomingBuffer.count {
            let chunk = Data(incomingBuffer[consumedTotal..<incomingBuffer.count])
            let caps = RCaps()
            let consumed = caps.parse(chunk)
            
            if consumed == 0 {
                // 当前剩余数据不足以组成完整 Caps，等待下次 BLE 分片
                break
            }
            if consumed < 0 {
                RGLog.error("[RGCxrClientBLE] parse caps failed, drop buffer. remained: \(chunk.count)")
                incomingBuffer.removeAll(keepingCapacity: true)
                return
            }
            if consumed > chunk.count {
                RGLog.error("[RGCxrClientBLE] parse caps consumed invalid size: \(consumed), chunk: \(chunk.count)")
                incomingBuffer.removeAll(keepingCapacity: true)
                return
            }
            
            consumedTotal += Int(consumed)
            handleDecodedCaps(caps)
        }
        
        if consumedTotal > 0 {
            incomingBuffer.removeSubrange(0..<consumedTotal)
        }
    }
    
    private func handleDecodedCaps(_ caps: RCaps) {
        let subCmd = caps.read_String(0)
        let json = caps.read_String(1)
        
        RGLog.info("[RGCxrClientBLE] subCmd: \(String(describing: subCmd)), json: \(String(describing: json))")
        if let jsonString = json,
           subCmd == RGCxrSubCmd.Sys_Bt_Gatt_Msg.rawValue {
            notifySubject.send(jsonString)
        }
    }
}

extension RGCxrClientBLE: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        RGLog.info("[RGCxrClientBLE] central state changed: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            if let targetDeviceName, !targetDeviceName.isEmpty {
                tryReconnectOrScan(trigger: "centralPoweredOn")
            } else {
                RGLog.info("[RGCxrClientBLE] poweredOn but no target name yet, skip scanning")
            }
        default:
            updateConnectionState(false)
            cancelReconnectSchedule()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        RGLog.info("[RGCxrClientBLE] didDiscover name: \(peripheral.name ?? "unknown"), id: \(peripheral.identifier.uuidString), rssi: \(RSSI)")
        if let targetDeviceName,
           peripheral.name != targetDeviceName {
            RGLog.debug("[RGCxrClientBLE] skip device by name mismatch, expected: \(targetDeviceName)")
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        RGLog.info("[RGCxrClientBLE] connecting peripheral: \(peripheral.identifier.uuidString)")
        let connectOptions = [CBConnectPeripheralOptionNotifyOnConnectionKey: true]
        central.connect(peripheral, options: connectOptions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.connectedDeviceName == nil {
                central.connect(peripheral, options: connectOptions)
            }
        }
    }


    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        RGLog.info("[RGCxrClientBLE] didConnect peripheral: \(peripheral.identifier.uuidString)")
        handleConnectedPeripheral(peripheral, trigger: "didConnect")
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        RGLog.error("[RGCxrClientBLE] didFailToConnect: \(peripheral.identifier.uuidString), error: \(error?.localizedDescription ?? "nil")")
        updateConnectionState(false)
        scheduleReconnectIfNeeded(reason: "didFailToConnect")
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        RGLog.info("[RGCxrClientBLE] didDisconnect peripheral: \(peripheral.identifier.uuidString)")
        self.writeCharacteristic = nil
        resetGattSessionState(clearQueuedWrites: true)
        updateConnectionState(false)
        if let error {
            RGLog.error("[RGCxrClientBLE] disconnected with error: \(error.localizedDescription)")
        }
        
        if isManualDisconnectRequested {
            RGLog.info("[RGCxrClientBLE] manual disconnect completed")
            isManualDisconnectRequested = false
            return
        }
        scheduleReconnectIfNeeded(reason: "didDisconnectPeripheral")
    }
}

extension RGCxrClientBLE: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil else {
            RGLog.error("[RGCxrClientBLE] discoverServices error: \(error!.localizedDescription)")
            return
        }
        RGLog.info("[RGCxrClientBLE] didDiscoverServices count: \(peripheral.services?.count ?? 0)")
        peripheral.services?.forEach { service in
            RGLog.debug("[RGCxrClientBLE] discovered service: \(service.uuid.uuidString)")
            guard service.uuid == RGCxrClientUUID.service.uuid else { return }
            RGLog.info("[RGCxrClientBLE] target service matched, discovering characteristics")
            peripheral.discoverCharacteristics([RGCxrClientUUID.write.uuid, RGCxrClientUUID.read.uuid], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard error == nil else {
            RGLog.error("[RGCxrClientBLE] discoverCharacteristics error: \(error!.localizedDescription)")
            return
        }
        RGLog.info("[RGCxrClientBLE] didDiscoverCharacteristics service: \(service.uuid.uuidString), count: \(service.characteristics?.count ?? 0)")
        service.characteristics?.forEach { characteristic in
            RGLog.debug("[RGCxrClientBLE] characteristic: \(characteristic.debugDescription)")
            let read = characteristic.properties.contains(.read)
            let write = characteristic.properties.contains(.write)
            let writeWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
            let notify = characteristic.properties.contains(.notify)
            let indicate = characteristic.properties.contains(.indicate)
            RGLog.info("[RGCxrClientBLE] read:\(read) write:\(write) writeWithoutResponse:\(writeWithoutResponse) notify:\(notify) indicate:\(indicate)")
            if characteristic.uuid == RGCxrClientUUID.write.uuid,
               write || writeWithoutResponse {
                writeCharacteristic = characteristic
                isWriteReady = true
                RGLog.info("[RGCxrClientBLE] write characteristic ready")
                flushWriteQueueIfPossible(trigger: "didDiscoverCharacteristicsFor/write")
            } else if characteristic.uuid == RGCxrClientUUID.read.uuid,
                      notify || indicate {
                RGLog.info("[RGCxrClientBLE] read characteristic ready, enabling notify")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
//        RGLog.info()
        guard error == nil else {
            RGLog.error("[RGCxrClientBLE] didUpdateValue error: \(error!.localizedDescription)")
            return
        }
        guard characteristic.uuid == RGCxrClientUUID.read.uuid,
              let data = characteristic.value,
              !data.isEmpty else {
            return
        }
//        RGLog.debug("[RGCxrClientBLE] didUpdateValue size: \(data.count)")
        handleIncomingData(data)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            RGLog.error("[RGCxrClientBLE] notify state update failed: \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == RGCxrClientUUID.read.uuid {
            isNotifyReady = characteristic.isNotifying
            if characteristic.isNotifying {
                flushWriteQueueIfPossible(trigger: "didUpdateNotificationStateFor/read")
            }
        }
        RGLog.info("[RGCxrClientBLE] notify state updated uuid: \(characteristic.uuid.uuidString), isNotifying: \(characteristic.isNotifying)")
//        
//        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true, block: { _ in
//            peripheral.readValue(for: characteristic)
//        })
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        cancelWriteAckTimeout()
        writeInFlight = false
        if let error {
            RGLog.error("[RGCxrClientBLE] didWriteValue failed, uuid: \(characteristic.uuid.uuidString), error: \(error.localizedDescription)")
            if let connectedPeripheral = self.peripheral {
                centralManager.cancelPeripheralConnection(connectedPeripheral)
            }
            return
        }
        RGLog.debug("[RGCxrClientBLE] didWriteValue success, uuid: \(characteristic.uuid.uuidString), pending queue: \(writeQueue.count)")
        flushWriteQueueIfPossible(trigger: "didWriteValueFor")
    }
}
