//
//  RGCxrSocketInternlDelegate.swift
//  RGCxrKit
//
//  Created by Ginger on 2025/4/7.
//

import Foundation
@_implementationOnly import RGCxrKit_Private
import RGCoreKit

internal class RGCxrSocketInternlDelegate: NSObject, RGCXRSocketProtocolDelegate {
    
    weak var cxrKit: RGCxrKitImp?
    
    public func onResponse(withReqId reqId: Int, args: RCaps) {
//        RGLog.info(reqId)
        cxrKit?.sendBackgroundTimerIfNeeded()
        cxrKit?.parseResponseData(reqId: reqId, args: args)
    }
    
    public func onNotify(withCmd cmd: String, args: RCaps) {
//        RGLog.info(cmd)
        cxrKit?.sendBackgroundTimerIfNeeded()
        cxrKit?.parseNotifyData(cmd: cmd, args: args)
    }
    
    public func onTransfer(withCmd cmd: String, args: RCaps, data: Data) {
        RGLog.info(cmd)
        cxrKit?.parseStreamData(cmd: cmd, args: args, data: data)
    }
    
    public func onStartAudioStream(withCodec codec: Int32, channels: UInt32, cmd: String, args: RCaps) {
        RGLog.info()
        cxrKit?.sendBackgroundTimerIfNeeded()
        cxrKit?.parseStartAudioStream(codec: codec, cmd: cmd, channels: channels, args: args)
    }
    
    func onAudioStream(with data: Data, timestamp: UInt64) {
        cxrKit?.sendBackgroundTimerIfNeeded()
        cxrKit?.parseAudioStream(data: data, timestamp: timestamp)
    }
    
    func onAudioStreamFinish() {
        RGLog.info()
        cxrKit?.parseAudioStreamFinish()
    }
    
    public func onLog(withContent content: String) {
        RGLog.debug(content)
    }
    
    func onSendData(with data: Data) {
        cxrKit?.sendBackgroundTimerIfNeeded()
        cxrKit?.send(data: data)
    }
    
    public func onAuthResultWithErrorCode(_ code: Int, majorVersion: Int, minorVersion: Int, macAddress: String?) {
        RGLog.info([
            "code": code,
            "majorVersion": majorVersion,
            "minorVersion": minorVersion,
            "macAddress": macAddress ?? ""
        ])
        cxrKit?.authResult(code: code, majorVersion: majorVersion, minorVersion: minorVersion, macAddress: macAddress)
    }

    public func onARTCFrame(with frameData: Data) {
        cxrKit?.parseARTCFrame(data: frameData)
    }
}
