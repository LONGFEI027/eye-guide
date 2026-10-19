//
//  RGCxrKit+ExternalAccessory.swift
//  RGCxrKit
//
//  Created by Ginger on 2025/6/21.
//

import Foundation
import ExternalAccessory
import RGCoreKit

internal extension String {
    /// 获取字符串的后四位字符
    /// - Returns: 后四位字符组成的字符串，如果原字符串长度小于四位则返回原字符串
    func lastFourCharacters() -> String {
        // 处理空字符串情况
        guard !isEmpty else {
            return self
        }
        
        // 计算需要获取的起始位置
        let startIndex = index(endIndex, offsetBy: -4, limitedBy: startIndex) ?? startIndex
        
        // 截取从起始位置到结尾的子字符串
        return String(self[startIndex..<endIndex])
    }
}

internal extension OutputStream {
    func write(_ data: Data) -> Int {
        return data.withUnsafeBytes({ (rawBufferPointer: UnsafeRawBufferPointer) -> Int in
            let bufferPointer = rawBufferPointer.bindMemory(to: UInt8.self)
            return self.write(bufferPointer.baseAddress!, maxLength: data.count)
        })
    }
}

extension RGCxrKitImp {
    
    internal func addMFINotification() {
        RGLog.api()
        NotificationCenter.default.addObserver(self, selector: #selector(mfiAccessoryDidDisconnect(_:)), name: NSNotification.Name.EAAccessoryDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mfiAccessoryDidConnect(_:)), name: NSNotification.Name.EAAccessoryDidConnect, object: nil)
    }
    
    @objc func mfiAccessoryDidDisconnect(_ notification: Notification) {
        RGLog.info(notification.userInfo)
    }
    
    @objc func mfiAccessoryDidConnect(_ notification: Notification) {
        RGLog.info(notification.userInfo)
    }

    /// 获取已连接的MFI设备
    internal func getMFIConnectedAccessories() -> [EAAccessory] {
        EAAccessoryManager.shared().connectedAccessories
    }
    
    internal func openMFIConnect(_ accessory: EAAccessory) -> Bool {
        RGLog.api(accessory.serialNumber)
        var protocolString = "com.rokid.aiglasses"
        if isGlobal {
            protocolString = "com.rokid.global.aiglasses"
        }
        if let session = EASession(accessory: accessory, forProtocol: protocolString) {
            session.inputStream?.open()
            session.inputStream?.delegate = self
            session.inputStream?.schedule(in: .main, forMode: .default)

            session.outputStream?.open()
            session.outputStream?.delegate = self
            session.outputStream?.schedule(in: .main, forMode: .default)

            currentSession = session
            currentAccessory = accessory
            accessory.delegate = self
            let name = accessory.serialNumber.lastFourCharacters()
            serialMap["Glasses2_\(name)"] = accessory.serialNumber
            serialMap["Glasses_\(name)"] = accessory.serialNumber
            serialMap["Bolon_\(name)"] = accessory.serialNumber
            return true
        } else {
            // 创建session失败
            RGLog.error("create session failed")
            return false
        }
    }
    
    internal func closeMFIConnect() {
        RGLog.api()
        currentSession?.inputStream?.close()
        currentSession?.outputStream?.close()
        currentSession?.inputStream?.remove(from: .main, forMode: .default)
        currentSession?.outputStream?.remove(from: .main, forMode: .default)
        currentSession?.inputStream?.delegate = nil
        currentSession?.outputStream?.delegate = nil
        currentSession = nil
        currentAccessory = nil
        outputData.removeAll()
    }
}

extension RGCxrKitImp: StreamDelegate {
    internal func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case Stream.Event.openCompleted:
            RGLog.info("Stream open completed")
//            connectionStatus = .socketConnected
        case Stream.Event.endEncountered:
            RGLog.info("End Encountered \(aStream.debugDescription)")
            cancelConnect(nil)
        case Stream.Event.hasBytesAvailable:
            if let aStream = aStream as? InputStream,
               isMFI {
                readBytes(from: aStream)
            }
        case Stream.Event.hasSpaceAvailable:
            if let _ = aStream as? OutputStream,
               isMFI {
                sendQueue.async { [weak self] in
                    self?.sendMFI()
                }
            }
        case Stream.Event.errorOccurred:
            RGLog.info("Stream error")
            cancelConnect(nil)
        default:
            RGLog.info("Unknown stream event")
        }
    }
    
    internal func sendMFI() {
        guard let ostream = currentSession?.outputStream,
              !outputData.isEmpty,
              ostream.hasSpaceAvailable else {
            return
        }
        let bytesWritten = ostream.write(outputData)
        
        RGLog.debug("bytesWritten = \(bytesWritten)")
        if bytesWritten > 0 && bytesWritten < outputData.count {
            outputData = outputData.dropFirst(bytesWritten)
        } else if bytesWritten >= outputData.count {
            outputData.removeAll()
        }
    }
    
    private func readBytes(from stream: InputStream) {
        readQueue.async { [weak self] in
            guard let self else { return }
            if stream.hasBytesAvailable {
                let bufferSize = 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead]) // 转换为 Data 类型
                    
                    // 转发原始数据到外部（在协议解析之前）
                    self.rawDataSubject.send(data)
                    
                    // 正常处理数据
                    socketProcotol?.handleReadPacket(withBuffer: data)
                    readBytes(from: stream)
                }
            }
        }
    }
}

extension RGCxrKitImp: EAAccessoryDelegate {
    
    func accessoryDidDisconnect(_ accessory: EAAccessory) {
        RGLog.info(accessory.serialNumber)
        if accessory.serialNumber == currentAccessory?.serialNumber {
            if !cancelBySelf {
                let expectedStatus: RGCxrConnectionStatus = connectionStatus == .bleReconnecting ? .bleReconnecting : .bleConnecting
                connectionStatus = expectedStatus
                foundPeripherals.removeAll(where: { $0.serialNumber == accessory.serialNumber })
                // 取消之前的延迟任务（如果有）
                delayedReconnectWorkItem?.cancel()
                
                // 创建新的延迟任务
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    RGLog.info("delayedReconnectWorkItem work")
                    // 检查状态是否仍然是预期的状态
                    if self.connectionStatus == expectedStatus {
                        foundPeripherals.removeAll(where: { $0.serialNumber == accessory.serialNumber })
                        self.realConnet(to: accessory.serialNumber, resetReconnectAttempts: true)
                    } else {
                        RGLog.info("connectionStatus changed, cancel delayed reconnect")
                    }
                }
                delayedReconnectWorkItem = workItem
                
                // 延迟3秒执行
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
            } else {
                connectionStatus = .idle
                cancelCallback?()
                cancelCallback = nil
            }
        }
    }
}
