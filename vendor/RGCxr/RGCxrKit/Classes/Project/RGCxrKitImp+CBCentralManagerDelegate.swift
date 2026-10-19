//
//  RGCxrKit.swift
//  RokidAIGlasses
//
//  Created by Ginger on 2025/2/27.
//

import Foundation
import CoreBluetooth
import RGCoreKit

extension RGCxrKitImp: CBCentralManagerDelegate {
    internal func centralManagerDidUpdateState(_ central: CBCentralManager) {
        RGLog.info(central.state.rawValue)
        
        if central.state == .poweredOn,
           waitingPowerOn,
           let serialNumber = connectingSerialNumber {
            realConnet(to: serialNumber, resetReconnectAttempts: true)
        } else if central.state == .poweredOff || central.state == .unsupported,
                  let connectedPeripheral = connectedPeripheral?.peripheral,
                  connectionStatus == .bleConnected || connectionStatus == .socketConnected {
            waitingPowerOn = true
            centralManager(central, didDisconnectPeripheral: connectedPeripheral, error: nil)
        }
        
        centralManagerDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrCentralManagerDelegate {
                DispatchQueue.main.async {
                    delegate.onCentralManagerStateChanged(central.state)
                }
            }
        }
    }
    
    internal func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        RGLog.info("\(dict)")
    }
    
    internal func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
//        RGLog.debug([
//            "peripheral": peripheral.debugDescription,
//            "advertisementData": "\(advertisementData)",
//            "RSSI": RSSI.stringValue
//        ])
        
        guard peripheral.name.isNotEmpty else {
            return
        }
        
        var serialNumber: String?
        
        if isAppInForeground {
            // 应用在前台，通过advertisementData获取serialNumber
            if let data = advertisementData["kCBAdvDataServiceData"] as? [CBUUID: Data],
               let data = data[RGCxrUUID.serialNumber.uuid],
               let extractedSerialNumber = String(data: data, encoding: .utf8),
               !extractedSerialNumber.isEmpty {
                serialNumber = extractedSerialNumber
            }
        } else {
            // 应用在后台，通过peripheral.name从serialMap获取serialNumber
            if let name = peripheral.name,
               let extractedSerialNumber = serialMap[name] {
                serialNumber = extractedSerialNumber
            }
        }
        
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            return
        }
        
        RGLog.info("serialNumber: \(serialNumber)")
        let cxrPeripheral = RGCxrPeripheral(serialNumber: serialNumber, peripheral: peripheral, rssi: RSSI)
        // 新的设备带有serialNumber，无脑替换
        foundPeripherals.removeAll(where: { $0.serialNumber == serialNumber })
        foundPeripherals.append(cxrPeripheral)
        scanDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrScanDelegate {
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        delegate.onPeripheralsChanged(new: cxrPeripheral, all: foundPeripherals)
                    }
                }
            }
        }
        
        // 扫描到了要连接的设备
        if serialNumber == scanningWaitingSerialNumber {
            realConnet(to: serialNumber, resetReconnectAttempts: false)
            // 如果只是连接发起的扫描，此时可以停止了
            if !isScanning {
                centralManager?.stopScan()
            }
            scanningWaitingSerialNumber = nil
        }
    }
    
    internal func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        RGLog.info(peripheral.debugDescription)
        guard connectingSerialNumber.isNotEmpty,
              let connectingSerialNumber = connectingSerialNumber else {
            RGLog.warn("connectingSerialNumber is empty")
            return
        }
        if let current = foundPeripherals.first(where: { $0.serialNumber == connectingSerialNumber }),
           peripheral.identifier.uuidString != current.peripheral.identifier.uuidString {
            RGLog.warn("unkown peripheral")
            return
        }
        
        // 更新BLE发现阶段并启动超时定时器
        updateBleDiscoveryStage(.connected)
        
        // 发现服务
        peripheral.delegate = self
        peripheral.discoverServices([RGCxrUUID.service.uuid])
        connectedPeripheral = RGCxrPeripheral(serialNumber: connectingSerialNumber, peripheral: peripheral, rssi: nil)
        connectionStatus = .bleConnected
        if let name = peripheral.name {
            serialMap[name] = connectingSerialNumber
        }
        self.connectingSerialNumber = nil
    }
    
    internal func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        RGLog.info([
            "peripheral": peripheral.debugDescription,
            "error": error?.localizedDescription ?? ""
        ])
        guard connectingSerialNumber.isNotEmpty,
              let connectingSerialNumber = connectingSerialNumber else {
            RGLog.warn("connectingSerialNumber is empty")
            return
        }
        if let current = foundPeripherals.first(where: { $0.serialNumber == connectingSerialNumber }),
           peripheral.identifier.uuidString != current.peripheral.identifier.uuidString {
            RGLog.warn("unkown peripheral")
            return
        }
        if cancelBySelf {
            cancelCallback?()
            cancelCallback = nil
        }
        // 重新去扫描
        foundPeripherals.removeAll(where: { $0.serialNumber == connectingSerialNumber })
        // 连接失败，重试
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if !cancelBySelf,
               let connectingSerialNumber = self.connectingSerialNumber,
               connectionStatus == .bleConnecting || connectionStatus == .bleReconnecting {
                connectionStatus = connectionStatus == .bleReconnecting ? .bleReconnecting : .bleConnecting
                realConnet(to: connectingSerialNumber, resetReconnectAttempts: false)
            }
        }
        // 配对信息被对方移除
        if let error = error as? NSError, error.code == 14 {
            // Peer removed pairing information
            connectionStatus = .idle
            connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrConnectionDelegate {
                    DispatchQueue.main.async {
                        delegate.onConnectionError(.peerRemovePairing)
                    }
                }
            }
        }
        // 要无限重试，直到连接成功
    }
    
    internal func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        RGLog.info([
            "peripheral": peripheral.debugDescription,
            "error": error?.localizedDescription ?? ""
        ])
        central.cancelPeripheralConnection(peripheral)
        guard let connectedPeripheral = connectedPeripheral,
              peripheral.identifier.uuidString == connectedPeripheral.peripheral.identifier.uuidString else {
            // 断开的不是已经连接的设备
            RGLog.warn("unkown peripheral")
            if peripheral.identifier.uuidString == lastCancelId {
                cancelCallback?()
                cancelCallback = nil
            }
            return
        }
        let error = error as? NSError
        if let error = error {
            RGLog.error([
                "error": error.localizedDescription,
                "code": error.code
            ])
        }
        stopBleServiceDiscoveryTimeoutTimer()
        if isMFI,
           connectionStatus == .socketConnected {
            RGLog.warn("is MFI")
            return
        }
        let serialNumber = connectedPeripheral.serialNumber
        // 重新去扫描
        foundPeripherals.removeAll(where: { $0.serialNumber == serialNumber })
        if badMtu {
            badMtu = false
            connectionStatus = connectionStatus == .bleReconnecting ? .bleReconnecting : .bleConnecting
            realConnet(to: serialNumber, resetReconnectAttempts: false)
        } else if !cancelBySelf {
            connectionStatus = connectionStatus == .bleReconnecting ? .bleReconnecting : .bleConnecting
            realConnet(to: serialNumber, resetReconnectAttempts: true)
        } else {
            connectionStatus = .idle
            cancelCallback?()
            cancelCallback = nil
        }
    }
    
    internal func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        RGLog.info([
            "peripheral": peripheral.debugDescription,
            "error": error?.localizedDescription ?? "",
            "isReconnecting": isReconnecting,
        ])
    }
    
    internal func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        RGLog.info([
            "event": event.rawValue,
            "peripheral": peripheral.debugDescription,
        ])
    }
    
    internal func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        RGLog.info()
    }
    
}
