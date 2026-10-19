//
//  RGCxrDefines.swift
//  RGCxrKit
//
//  Created by Ginger on 2025/9/24.
//

import Foundation
import CoreBluetooth

// 蓝牙连接状态
public enum RGCxrConnectionStatus: UInt {
    // 未连接
    case idle = 0
    // BLE连接中
    case bleConnecting
    // BLE重连中，连接一分钟没有连上则会进入这个状态
    case bleReconnecting
    // BLE连接成功
    case bleConnected
    // socket连接成功
    case socketConnected
}

// 蓝牙设备对象
public class RGCxrPeripheral: NSObject {
    public var serialNumber: String
    public var peripheral: CBPeripheral
    public var rssi: NSNumber?
    
    init(serialNumber: String, peripheral: CBPeripheral, rssi: NSNumber? = nil) {
        self.serialNumber = serialNumber
        self.peripheral = peripheral
        self.rssi = rssi
    }
}

// 蓝牙连接错误码
public enum RGCxrConnectionError: UInt {
    // 未知错误
    case unknown = 0
    // 配对信息被对方移除
    case peerRemovePairing
    // 眼镜已经与其他设备配对
    case notSuited
    // 鉴权失败
    case authFailed
    // 非MFi设备
    case noMFi
}


public protocol RGCxrConnectionDelegate: NSObjectProtocol {
    
    /// 蓝牙连接状态变更
    /// - Parameters:
    ///   - old: 旧状态
    ///   - new: 新状态
    func onConnectionStatusChanged(old: RGCxrConnectionStatus, new: RGCxrConnectionStatus)
    
    /// 蓝牙连接遇到不可恢复的错误
    /// - Parameter error: 错误码
    func onConnectionError(_ error: RGCxrConnectionError)
}

public protocol RGCxrCentralManagerDelegate: NSObjectProtocol {
    
    /// 蓝牙开关状态变更
    /// - Parameter state: 最新状态
    func onCentralManagerStateChanged(_ state: CBManagerState)
}

public protocol RGCxrScanDelegate: NSObjectProtocol {
    
    /// 蓝牙设备扫描列表变更
    /// - Parameters:
    ///   - new: 扫到的设备
    ///   - all: 当前所有发现的设备
    func onPeripheralsChanged(new: RGCxrPeripheral, all: [RGCxrPeripheral])
}

public protocol RGCxrAccountDelegate: NSObjectProtocol {
    // 连接过程中眼镜会告知当前绑定的账号，app决定是否连接，如果账号不同，连接后眼镜会进行清理动作，不监听此代理则默认直接清理数据并更新账号
    func onAccount(_ account: String?, callback: ((Bool, String?) -> Void)?)
    
    // 回连过程中检查新账号
    func onAccountReconnect(_ account: String) -> Bool
}

public protocol RGCxrDataDelegate: NSObjectProtocol {

    // 消息通知
    func onDataNotify(_ model: RGCxrDataResponse)
    
    // 流式数据
    func onStreamReceived(_ model: RGCxrStreamResponse)
    
    // 眼镜开始往APP发送音频
    func onStartAudioStream(codec: Int32, type: String, channels: UInt32)
    
    // 音频数据
    func onAudioStream(data: Data, timestamp: UInt64)
    
    // 音频结束
    func onAudioStreamFinish()

    // ARTC视频帧数据
    func onARTCFrame(data: Data)
}

public protocol RGCxrAudioStreamDelegate: NSObjectProtocol {
    
    /// 音频开始播放回调
    /// - Parameter streamId: 音频流ID
    func onAudioStreamStartPlay(streamId: Int)
    
    /// 音频结束播放回调
    /// - Parameter streamId: 音频流ID
    /// - Parameter code: 错误码
    func onAudioStreamStopPlay(streamId: Int, code: Int)
}
