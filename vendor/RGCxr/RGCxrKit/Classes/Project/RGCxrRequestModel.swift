//
//  RRequestModel.swift
//  Pods
//
//  Created by Ginger on 2025/4/2.
//

import CoreBluetooth

internal class RGCxrRequestModel {
    internal var reqId: Int32 = 0
    internal var requestTime: TimeInterval = 0
    internal var cmd: String = ""
    internal var onResponse: ((RGCxrBaseResponse) -> Void)?
    
    internal init(reqId: Int32, requestTime: TimeInterval, cmd: String, onResponse: ((RGCxrBaseResponse) -> Void)?) {
        self.reqId = reqId
        self.requestTime = requestTime
        self.onResponse = onResponse
        self.cmd = cmd
    }
}
