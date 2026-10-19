import Foundation
import CoreBluetooth
import RGCoreKit
@_implementationOnly import RGCxrKit_Private

// 发送数据
extension RGCxrKitImp {
    
    // 解析请求结果数据
    internal func parseResponseData(reqId: Int, args: RCaps){
        /**
         response数据包格式
         [0] uint32 type -- 0
         [1] int32 reqid
         [2] int32 status
         [3] string cmd
         [4] caps data -- 可选, 发送端app自定义
         */
        let responseModel = RGCxrDataResponse()
        if let dataList = readDataFromCaps(args) {
            if let subCmd = dataList[safe: 0] as? String {
                responseModel.subCmd = subCmd
            }
            if dataList.count > 1 {
                responseModel.responseData = dataList[1]
            }
        }
        responseModel.reqId = Int32(reqId)
        requestQueue.getModel(by: responseModel.reqId) { [weak self] model in
            if let model = model {
                responseModel.cmd = model.cmd
                RGLog.info(responseModel.stringValue())
                model.onResponse?(responseModel)
                self?.requestQueue.removeModel(model)
            } else {
                RGLog.warn("model not exist")
                // 如果上层调用UnSync_Count没设置回调，则作为notify给出去，只处理这一个类型，降低影响
                if responseModel.subCmd == RGCxrSubCmd.UnSync_Count.rawValue {
                    responseModel.cmd = RGCxrCmd.Med.rawValue
                    self?.dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                        if let delegate = delegate as? RGCxrDataDelegate {
                            delegate.onDataNotify(responseModel)
                        }
                    }
                    self?.dataNotifySubject.send(responseModel)
                }
            }
        }
    }
    
    // 解析短消息通知数据
    internal func parseNotifyData(cmd: String, args: RCaps) {
        /**
         短消息notify数据包格式
         [0] uint32 type -- 1
         [1] string cmd
         [2] caps data -- 可选, 发送端app自定义
         */
        
        /// 专门处理CXR-L的协议
        if cmd == "Sys", let dataList = readDataFromCaps(args), let subCmd = dataList[safe: 0] as? String {
            if subCmd == "F" {
                handleFragHeader(dataList: dataList)
                return
            }
            if subCmd == "C" {
                if let assembled = handleFragChunk(dataList: dataList) {
                    forwardAssembledSysBtGattMsg(assembled)
                }
                return
            }
        }

        let responseModel = RGCxrDataResponse()
        responseModel.cmd = cmd
        if let dataList = readDataFromCaps(args) {
            if let subCmd = dataList[safe: 0] as? String {
                responseModel.subCmd = subCmd
            }
            if dataList.count > 1 {
                responseModel.responseData = dataList[1]
            }
            if dataList.count > 2 {
                responseModel.responseDataEx = dataList[2]
            }
        }
        if cmd != "Pay" {
            RGLog.info(responseModel.stringValue())
        }
        
        if !dealInternalNotifyData(cmd: cmd, responseModel: responseModel) {
            dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrDataDelegate {
                    delegate.onDataNotify(responseModel)
                }
            }
            dataNotifySubject.send(responseModel)
        }
    }
    
    private func handleFragHeader(dataList: [Any]) {
        guard dataList.count >= 3,
              let totalSize = dataList[1] as? Int32,
              let chunkCount = dataList[2] as? Int32,
              totalSize > 0, chunkCount > 0 else {
            fragBuffer.removeAll()
            return
        }
        fragBuffer.removeAll()
        fragTotalSize = Int(totalSize)
        fragChunkCount = Int(chunkCount)
        RGLog.debug("[CXRKit] frag header: total=\(fragTotalSize), chunks=\(fragChunkCount)")
    }

    private func handleFragChunk(dataList: [Any]) -> Data? {
        guard fragChunkCount > 0,
              dataList.count >= 3,
              let idx = dataList[1] as? Int32,
              let chunkData = dataList[2] as? Data else { return nil }
        let i = Int(idx)
        guard i >= 0, i < fragChunkCount else { return nil }
        fragBuffer[i] = chunkData
        guard fragBuffer.count == fragChunkCount else { return nil }
        let expected = fragTotalSize
        var assembled = Data()
        for j in 0..<fragChunkCount {
            guard let d = fragBuffer[j] else {
                fragBuffer.removeAll()
                fragChunkCount = 0
                fragTotalSize = 0
                return nil
            }
            assembled.append(d)
        }
        fragBuffer.removeAll()
        fragChunkCount = 0
        fragTotalSize = 0
        return assembled.count == expected ? assembled : nil
    }

    private func forwardAssembledSysBtGattMsg(_ payload: Data) {
        let caps = RCaps()
        guard caps.parse(payload) > 0 else {
            RGLog.error("[CXRKit] frag assembled parse failed")
            return
        }
        let responseModel = RGCxrDataResponse()
        responseModel.cmd = "Sys"
        responseModel.subCmd = RGCxrSubCmd.Sys_Bt_Gatt_Msg.rawValue
        if let dataList = readDataFromCaps(caps) {
            if dataList.count > 1 { responseModel.responseData = dataList[1] }
            if dataList.count > 2 { responseModel.responseDataEx = dataList[2] }
        }
        RGLog.info("[CXRKit] frag assembled, forwarding as Sys_Bt_Gatt_Msg")
        if !dealInternalNotifyData(cmd: "Sys", responseModel: responseModel) {
            dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrDataDelegate {
                    delegate.onDataNotify(responseModel)
                }
            }
            dataNotifySubject.send(responseModel)
        }
    }

    internal func resetFragState() {
        fragBuffer.removeAll()
        fragChunkCount = 0
        fragTotalSize = 0
    }

    internal func dealInternalNotifyData(cmd: String, responseModel: RGCxrDataResponse) -> Bool {
        if cmd == "Sys",
           responseModel.subCmd == "GlassRemoveBond",
           let serialNumber = currentAccessory?.serialNumber {
            addToBlacklist(serialNumber)
            setServiceRecord("", for: serialNumber)
            setGlassesMacAddress("", for: serialNumber)
            cancelConnect(nil)
            connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrConnectionDelegate {
                    DispatchQueue.main.async {
                        delegate.onConnectionError(.peerRemovePairing)
                    }
                }
            }
            return true
        } else if cmd == "Sys",
                  responseModel.subCmd == "Tts_PlayFinish",
                  let str = responseModel.responseData as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let result = json["result"] as? Int,
                  let id = json["id"] as? Int {
            audioStreamDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrAudioStreamDelegate {
                    DispatchQueue.main.async {
                        delegate.onAudioStreamStopPlay(streamId: id, code: result)
                    }
                }
            }
            return true
        } else if cmd == "Sys",
                  responseModel.subCmd == "Tts_PlayStart",
                  let str = responseModel.responseData as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = json["id"] as? Int {
            audioStreamDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrAudioStreamDelegate {
                    DispatchQueue.main.async {
                        delegate.onAudioStreamStartPlay(streamId: id)
                    }
                }
            }
            return true
        }
        return false
    }
    
    // 解析流式数据
    internal func parseStreamData(cmd: String, args: RCaps, data: Data) {
        let responseModel = RGCxrStreamResponse()
        responseModel.cmd = cmd
        if let dataList = readDataFromCaps(args) {
            if let subCmd = dataList[safe: 0] as? String {
                responseModel.subCmd = subCmd
            }
            if dataList.count > 1 {
                responseModel.responseData = dataList[1]
            }
        }
        responseModel.streamData = data
        RGLog.info(responseModel.stringValue())
        dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrDataDelegate {
                delegate.onStreamReceived(responseModel)
            }
        }
        streamSubject.send(responseModel)
    }
    
    internal func parseStartAudioStream(codec: Int32, cmd: String, channels: UInt32, args: RCaps) {
        dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrDataDelegate {
                delegate.onStartAudioStream(codec: codec, type: cmd, channels: channels)
            }
        }
        startAudioStreamSubject.send((codec: codec, type: cmd, channels: channels))
    }
    
    internal func parseAudioStream(data: Data, timestamp: UInt64) {
        dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrDataDelegate {
                delegate.onAudioStream(data: data, timestamp: timestamp)
            }
        }
        audioStreamSubject.send((data: data, timestamp: timestamp))
    }
    
    internal func parseAudioStreamFinish() {
        dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrDataDelegate {
                delegate.onAudioStreamFinish()
            }
        }
        audioStreamFinishSubject.send()
    }
    
    internal func authResult(code: Int, majorVersion: Int, minorVersion: Int, macAddress: String?) {
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        if code < 0,
           connectionStatus != .idle {
            connectionStatus = .idle
            connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
                if let delegate = delegate as? RGCxrConnectionDelegate {
                    DispatchQueue.main.async {
                        // -6表示眼镜已经被其他设备连接
                        delegate.onConnectionError(code == -6 ? .notSuited : .authFailed)
                    }
                }
            }
        } else {
            // 保存mac地址
            if let macAddress = macAddress,
               !macAddress.isEmpty {
                setMacAddress(macAddress)
            }
            verifyResult.uuid = true
            if verifyResult.account == true,
               connectionStatus != .socketConnected {
                connectionStatus = .socketConnected
            }
        }
    }
    
    internal func writeDataToCaps(_ caps: RCaps, data: Any) {
        if let dataList = data as? Array<Any> {
            dataList.forEach { tData in
                writeDataToCaps(caps, data: tData)
            }
        } else {
            if let v = data as? String {
                caps.write_String(v)
            } else if let v = data as? Int32 {
                caps.write_Int32(v)
            } else if let v = data as? UInt32 {
                caps.write_UInt32(v)
            } else if let v = data as? Int64 {
                caps.write_Int64(v)
            } else if let v = data as? UInt64 {
                caps.write_UInt64(v)
            } else if let v = data as? Float {
                caps.write_Float(v)
            } else if let v = data as? Double {
                caps.write_Double(v)
            } else if let v = data as? Int32 {
                caps.write_Int32(v)
            } else if let v = data as? Data {
                caps.write_Binary(v)
            }
        }
    }
    
    internal func readDataFromCaps(_ caps: RCaps) -> [Any]? {
        var capsDataList: [Any] = []
        for idx in (0..<caps.size()) {
            let type: String = caps.type(idx)
            switch type {
            case "i":
                capsDataList.append(caps.read_Int32(idx))
            case "u":
                capsDataList.append(caps.read_UInt32(idx))
            case "l":
                capsDataList.append(caps.read_Int64(idx))
            case "k":
                capsDataList.append(caps.read_UInt64(idx))
            case "f":
                capsDataList.append(caps.read_Float(idx))
            case "d":
                capsDataList.append(caps.read_Double(idx))
            case "S":
                if let v = caps.read_String(idx) {
                    capsDataList.append(v)
                }
            case "B":
                if let v = caps.read_Binary(idx) {
                    capsDataList.append(v)
                }
            case "O":
                if let v = caps.read_Caps(idx) {
                    capsDataList.append(v)
                }
            default: break
            }
        }
        return capsDataList
    }

    internal func parseARTCFrame(data: Data) {
        dataDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrDataDelegate {
                delegate.onARTCFrame(data: data)
            }
        }
    }
}
