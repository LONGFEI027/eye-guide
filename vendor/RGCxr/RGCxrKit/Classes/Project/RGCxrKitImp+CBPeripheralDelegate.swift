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

extension RGCxrKitImp: CBPeripheralDelegate {
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheralDidUpdateRSSI(_ peripheral: CBPeripheral, error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
        
        // 更新BLE发现阶段
        updateBleDiscoveryStage(.servicesDiscovered)
        
        if let service = peripheral.services?.first(where: { $0.uuid == RGCxrUUID.service.uuid }) {
            // 发现特征
            peripheral.discoverCharacteristics([RGCxrUUID.socket.uuid,
                                                RGCxrUUID.write.uuid,
                                                RGCxrUUID.createBoud.uuid,
                                                RGCxrUUID.askConnect.uuid,
                                                RGCxrUUID.read.uuid], for: service)

            let withResponse = peripheral.maximumWriteValueLength(for: .withResponse)
            let withoutResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
            RGLog.info(
                ["withResponse": withResponse,
                 "withoutResponse": withoutResponse]
            )
            // 处理mtu突变的情况
            let mtu = min(withResponse, withoutResponse) - 2
            if mtu < 30 {
                RGLog.info("badMtu \(mtu)")
                badMtu = true
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        } else {
            // 没有找到目标服务，触发超时处理
            RGLog.error("Target service not found")
            handleBleServiceDiscoveryTimeout()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
        guard let characteristics = service.characteristics else {
            RGLog.error("No characteristics found")
            return
        }

        // 更新BLE发现阶段
        updateBleDiscoveryStage(.characteristicsDiscovered)
        
        // 订阅特征值
        characteristics.forEach { characteristic in
            RGLog.info("characteristics: \(characteristic.uuid) | \(characteristic.properties) | \(characteristic.isNotifying)")
            peripheral.discoverDescriptors(for: characteristic)
            
            if characteristic.uuid.uuidString == RGCxrUUID.read.rawValue || characteristic.uuid.uuidString == RGCxrUUID.askConnect.rawValue,
               characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid.uuidString == RGCxrUUID.write.rawValue,
                      characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
            } else if characteristic.uuid.uuidString == RGCxrUUID.createBoud.rawValue,
                      characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                createBoudCharacteristic = characteristic
            }
                      
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        RGLog.info(characteristic.uuid)
        // 眼镜发来的数据
        guard let data = characteristic.value else {
            RGLog.error("characteristic value empty")
            return
        }
        if characteristic.uuid.uuidString == RGCxrUUID.socket.rawValue {
            RGLog.info(characteristic.uuid)
            let caps = RCaps()
            caps.parse(data)
            let mfi = caps.read_UInt32(0)
            let serviceRecord = caps.read_String(1)
            let account = caps.read_String(2)
            let panel = caps.read_UInt32(3)
            let version = caps.read_UInt32(4)
            let glassesMacAddress = caps.read_String(5)
            RGLog.info([
                "mfi": mfi,
                "uuid": serviceRecord ?? "",
                "account": account ?? "",
                "version": version,
                "panel": panel,
                "mac address": glassesMacAddress ?? ""
            ])
            
            isMFI = (mfi == 1 && version > 0 && version < 0x80000000)
            if !isMFI {
                RGLog.error("not mfi")
                cancelConnect(nil)
                connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                    if let delegate = delegate as? RGCxrConnectionDelegate {
                        DispatchQueue.main.async {
                            delegate.onConnectionError(.noMFi)
                        }
                    }
                }
                return
            }
            
            if serviceRecord.isNilOrEmpty,
               getServiceRecord(for: connectedPeripheral?.serialNumber).isNilOrEmpty {
                RGLog.error("ask socket connect uuid error")
                cancelConnect(nil)
                connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                    if let delegate = delegate as? RGCxrConnectionDelegate {
                        DispatchQueue.main.async {
                            delegate.onConnectionError(.notSuited)
                        }
                    }
                }
                return
            }
            
            setGlassesMacAddress(glassesMacAddress, for: connectedPeripheral?.serialNumber)
            setAccount(account, for: connectedPeripheral?.serialNumber)
            
            if let delegate = accountDelegate {
                delegate.onAccount(account) { [weak self] ret, newAccount in
                    RGLog.info("onAccount ret:\(ret) newAccount:\(String(describing: newAccount))")
                    // 上层同意了
                    if ret {
                        self?.verifyResult.account = true
                        var changeAccount: String? = nil
                        if let newAccount = newAccount,
                           newAccount != account {
                            changeAccount = newAccount
                        }
                        if self?.isMFI == true {
                            self?.mfiConnect(peripheral, serviceRecord: serviceRecord, changeAccount: changeAccount)
                        } else {
                            self?.verifyUuid(serviceRecord)
                            if let changeAccount = changeAccount {
                                self?.socketProcotol?.changeRokidAccount(changeAccount)
                                self?.setAccount(changeAccount, for: self?.connectedPeripheral?.serialNumber)
                            }
                        }
                    } else {
                        RGLog.info()
                        self?.cancelConnect(nil)
                    }
                }
            } else {
                verifyResult.account = true
                if isMFI {
                    mfiConnect(peripheral, serviceRecord: serviceRecord, changeAccount: nil)
                } else {
                    verifyUuid(serviceRecord)
                }
            }
        } else if characteristic.uuid.uuidString == RGCxrUUID.read.rawValue,
                  !isMFI {
            RGLog.info("data length: \(data.count)")
            let copiedData = Data(data)  // 在当前线程复制数据
            readQueue.async { [weak self] in
                self?.socketProcotol?.handleReadPacket(withBuffer: copiedData)
            }
        } else if characteristic.uuid.uuidString == RGCxrUUID.askConnect.rawValue {
            let caps = RCaps()
            caps.parse(data)
            let cmd = caps.read_UInt32(0)
            let result = caps.read_Int32(1)
            // 眼镜回复手机MFI连接发起
            if cmd == 0x1101 {
                RGLog.info("cmd: 0x1101, result: \(result)")
                if result == -1 {
                    // uuid验证不通过, iphone需重新执行配对流程
                    cancelConnect(nil)
                    connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                        if let delegate = delegate as? RGCxrConnectionDelegate {
                            DispatchQueue.main.async {
                                delegate.onConnectionError(.notSuited)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func mfiConnect(_ peripheral: CBPeripheral, serviceRecord: String?, changeAccount: String?) {
        RGLog.api()
        if let serialNumber = connectedPeripheral?.serialNumber {
            if let mfiDevice = getMFIConnectedAccessories().first(where: { $0.serialNumber == serialNumber }) {
                RGLog.info("find mfi device")
                if openMFIConnect(mfiDevice) == true {
                    self.verifyUuid(serviceRecord)
                    if let changeAccount = changeAccount {
                        self.socketProcotol?.changeRokidAccount(changeAccount)
                        self.setAccount(changeAccount, for: serialNumber)
                    }
                }
            } else if let createBoudCharacteristic = createBoudCharacteristic {
                let currentSerialNumber = connectedPeripheral?.serialNumber
                let sameRecord = serviceRecord == getServiceRecord(for: currentSerialNumber)
                /// 当前是重新配对，或者眼镜给的serviceRecord与本地记录的一样，或者眼镜给的serviceRecord是空，这三种情况都要尝试去连接
                if isNewPairing || sameRecord || serviceRecord?.isEmpty == true {
                    let localRecord = getServiceRecord(for: currentSerialNumber)
                    RGLog.info("no mfi device, serviceRecord: \(String(describing: serviceRecord)), localRecord: \(String(describing: localRecord))")
                    if let askRecord = serviceRecord.isNilOrEmpty ? getServiceRecord(for: currentSerialNumber) : serviceRecord,
                       !askRecord.isEmpty {
                        
                        let firstCaps = RCaps()
                        firstCaps.write_UInt32(0x1102)
                        firstCaps.write_Int32(isGlobal ? 1 : 0)
                        if let data = firstCaps.serialize() {
                            RGLog.info("data.count: \(data.count)")
                            peripheral.writeValue(data, for: createBoudCharacteristic, type: .withResponse)
                        } else {
                            RGLog.error("firstCaps serialize failed")
                        }
                        
                        RGLog.info("askRecord: \(askRecord)")
                        let caps = RCaps()
                        caps.write_UInt32(0x1100)
                        caps.write_String(askRecord)
                        if let address = getMacAddress(),
                           !address.isEmpty {
                            RGLog.info("address: \(address)")
                            caps.write_String(address)
                        }
                        if let data = caps.serialize() {
                            RGLog.info("data.count: \(data.count)")
                            peripheral.writeValue(data, for: createBoudCharacteristic, type: .withResponse)
                        } else {
                            RGLog.error("caps serialize failed")
                            cancelConnect(nil)
                            connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                                if let delegate = delegate as? RGCxrConnectionDelegate {
                                    DispatchQueue.main.async {
                                        delegate.onConnectionError(.unknown)
                                    }
                                }
                            }
                        }
                    } else {
                        RGLog.error("ask socket connect uuid error")
                        cancelConnect(nil)
                        connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                            if let delegate = delegate as? RGCxrConnectionDelegate {
                                DispatchQueue.main.async {
                                    delegate.onConnectionError(.unknown)
                                }
                            }
                        }
                    }
                    getMFIDevices(serviceRecord: serviceRecord, changeAccount: changeAccount, serialNumber: serialNumber, retry: 0)
                } else {
                    RGLog.error("眼镜已经被其他设备配对了，重新发起眼镜配对！！！！")
                    cancelConnect(nil)
                    connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                        if let delegate = delegate as? RGCxrConnectionDelegate {
                            DispatchQueue.main.async {
                                delegate.onConnectionError(.notSuited)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func getMFIDevices(serviceRecord: String?, changeAccount: String?, serialNumber: String?, retry: Int) {
        RGLog.api("retry: \(retry)")
        if retry > 50 {
            // 超出重试次数，最大40次，40秒
            clearMacAddress()
            if let serialNumber = serialNumber {
                RGLog.info("\(connectionStatus)")
                if connectionStatus == .bleConnecting || connectionStatus == .bleConnected {
                    RGLog.info("BLE Reconnecting")
                    connectionStatus = .bleReconnecting
                }
                realConnet(to: serialNumber, resetReconnectAttempts: true)
            } else {
                RGLog.error("serialNumber is nil")
                connectionStatus = .idle
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if connectionStatus != .bleConnected {
                RGLog.warn("connectionStatus: \(connectionStatus.rawValue)")
                return
            }
            if let mfiDevice = getMFIConnectedAccessories().first(where: { $0.serialNumber == serialNumber }) {
                if openMFIConnect(mfiDevice) == true {
                    verifyUuid(serviceRecord)
                    if let changeAccount = changeAccount {
                        socketProcotol?.changeRokidAccount(changeAccount)
                        setAccount(changeAccount, for: serialNumber)
                    }
                }
            } else {
                getMFIDevices(serviceRecord: serviceRecord, changeAccount: changeAccount, serialNumber: serialNumber, retry: retry + 1)
            }
        }
    }
    
    internal func verifyUuid(_ serviceRecord: String?) {
        RGLog.api(serviceRecord)
        let currentSerialNumber = connectedPeripheral?.serialNumber ?? serialNumber
        // 优先使用眼镜给的serviceRecord，如果眼镜没有给说明他现在是已匹配状态，使用本地记录的serviceRecord去认证
        if let serviceRecord = serviceRecord {
            // 眼镜给的serviceRecord为空，说明已经被配对过了
            if serviceRecord.isEmpty {
                // 本地存过serviceRecord，直接用这个serviceRecord去跟眼镜握手
                if let record = getServiceRecord(for: currentSerialNumber),
                   !record.isEmpty {
                    RGLog.info("use keychain serviceRecord: \(record)")
                    socketProcotol?.verify(withServiceRecord: record, extra: isGlobal ? 195 : 194)
                    // 先处理成发了就当同意，兼容老版本的眼镜逻辑
                    if !isMFI {
                        verifyResult.uuid = true
                        if verifyResult.account == true {
                            connectionStatus = .socketConnected
                        }
                    }
                } else {
                    // 本地没有serviceRecord，直接可以视为握手失败
                    RGLog.error("眼镜已经被其他设备配对了，重新发起眼镜配对！！！！")
                    cancelConnect(nil)
                    connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                        if let delegate = delegate as? RGCxrConnectionDelegate {
                            DispatchQueue.main.async {
                                delegate.onConnectionError(.notSuited)
                            }
                        }
                    }
                }
            } else {
                // 眼镜给的serviceRecord不为空，说明是新配对
                let sameRecord = serviceRecord == getServiceRecord(for: currentSerialNumber)
                RGLog.info("isNewPairing: \(isNewPairing) sameRecord: \(sameRecord)")
                if isNewPairing || sameRecord {
                    // 如果App也是重新配对，或者眼镜的serviceRecord与本地记录的一样，则直接使用这个serviceRecord
                    RGLog.info("set serviceRecord: \(serviceRecord)")
                    setServiceRecord(serviceRecord, for: currentSerialNumber)
                    socketProcotol?.verify(withServiceRecord: serviceRecord, extra: isGlobal ? 195 : 194)
                    // 先处理成发了就当同意，兼容老版本的眼镜逻辑
                    if !isMFI {
                        verifyResult.uuid = true
                        if verifyResult.account == true {
                            connectionStatus = .socketConnected
                        }
                    }
                } else {
                    RGLog.error("眼镜已经被其他设备配对了，重新发起眼镜配对！！！！")
                    cancelConnect(nil)
                    connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                        if let delegate = delegate as? RGCxrConnectionDelegate {
                            DispatchQueue.main.async {
                                delegate.onConnectionError(.notSuited)
                            }
                        }
                    }
                }
            }
        } else {
            RGLog.info()
            cancelConnect(nil)
            return
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        // 自己写数据
        RGLog.info(error?.localizedDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: (any Error)?) {
        RGLog.info(characteristic.uuid)
        
        // 更新BLE发现阶段
        updateBleDiscoveryStage(.descriptorsDiscovered)
        
        // 主动读取socket信息
        if characteristic.uuid.uuidString == RGCxrUUID.socket.rawValue {
            peripheral.readValue(for: characteristic)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: (any Error)?) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        RGLog.info(peripheral.debugDescription)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        RGLog.info([
            "peripheral": peripheral.debugDescription,
            "error": error.debugDescription
        ])
    }
}

extension RGCxrKitImp {
    internal func send(data: Data) -> Void {
        sendQueue.async { [weak self] in
            guard let self else { return }
            if isMFI {
                outputData.append(data)
                sendMFI()
            } else {
                if let connectedPeripheral = connectedPeripheral,
                   let writeCharacteristic = writeCharacteristic {
                    if writeCharacteristic.properties.contains(.write) {
                        RGLog.debug()
                        connectedPeripheral.peripheral.writeValue(data, for: writeCharacteristic, type: .withResponse)
                    } else if writeCharacteristic.properties.contains(.writeWithoutResponse) {
                        connectedPeripheral.peripheral.writeValue(data, for: writeCharacteristic, type: .withoutResponse)
                    }
                }
            }
        }
    }
}
