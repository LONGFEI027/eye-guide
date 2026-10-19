import Foundation
import Network
import RGCoreKit

internal struct RGCxrClientAudioStreamInfo {
    internal let port: UInt16
    internal let codec: Int32
    internal let type: String
    internal let channels: UInt32
}

internal struct RGCxrClientAudioPacket {
    internal let data: Data
    internal let timestamp: UInt64
}

internal protocol RGCxrClientAudioStreamServiceDelegate: AnyObject {
    func audioStreamServiceDidStart(info: RGCxrClientAudioStreamInfo)
    func audioStreamServiceDidConnect(port: UInt16)
    func audioStreamServiceDidReceive(packet: RGCxrClientAudioPacket)
    func audioStreamServiceDidStop()
    func audioStreamServiceDidFail(error: Error)
    func audioStreamServiceSendPing()
}

internal final class RGCxrClientAudioStreamService {
    
    private enum AudioStreamServiceError: LocalizedError {
        case invalidPort(UInt16)
        
        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "无效的音频端口: \(port)"
            }
        }
    }
    
    internal weak var delegate: RGCxrClientAudioStreamServiceDelegate?
    
    private let queue = DispatchQueue(label: "com.rokid.cxr.client.audio", qos: .userInitiated)
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatTimeoutWorkItem: DispatchWorkItem?
    
    private let heartbeatInterval: TimeInterval = 10.0
    private let heartbeatTimeout: TimeInterval = 25.0
    
    private var currentPort: UInt16?
    private var isStopping = false
    
    internal func start(info: RGCxrClientAudioStreamInfo) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopInternal(notify: false)
            
            guard let nwPort = NWEndpoint.Port(rawValue: info.port) else {
                self.delegate?.audioStreamServiceDidFail(error: AudioStreamServiceError.invalidPort(info.port))
                return
            }
            
            self.currentPort = info.port
            self.receiveBuffer.removeAll()
            self.delegate?.audioStreamServiceDidStart(info: info)
            
            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            self.connection = connection
            
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    RGLog.info("[CxrClient][Audio] TCP connected, port: \(info.port)")
                    self.delegate?.audioStreamServiceDidConnect(port: info.port)
                    self.startReceiveLoop()
                    self.startHeartbeatTimer()
                    self.resetHeartbeatTimeoutTimer()
                case .failed(let error):
                    RGLog.error("[CxrClient][Audio] TCP failed: \(error)")
                    self.delegate?.audioStreamServiceDidFail(error: error)
                    self.stop()
                case .cancelled:
                    RGLog.info("[CxrClient][Audio] TCP cancelled")
                    self.stop()
                default:
                    break
                }
            }
            
            connection.start(queue: self.queue)
        }
    }
    
    internal func stop() {
        queue.async { [weak self] in
            self?.stopInternal(notify: true)
        }
    }
    
    internal func onKeepAliveReceived() {
        queue.async { [weak self] in
            guard let self = self, self.connection != nil else { return }
            self.resetHeartbeatTimeoutTimer()
        }
    }
    
    private func stopInternal(notify: Bool) {
        if isStopping { return }
        isStopping = true
        let hadConnection = connection != nil
        
        cancelHeartbeatTimer()
        cancelHeartbeatTimeoutTimer()
        
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        currentPort = nil
        
        if notify && hadConnection {
            delegate?.audioStreamServiceDidStop()
        }
        isStopping = false
    }
    
    private func startReceiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard self.connection != nil else { return }
            
            if let error = error {
                self.delegate?.audioStreamServiceDidFail(error: error)
                self.stop()
                return
            }
            
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeBufferedPackets()
            }
            
            if isComplete {
                RGLog.info("[CxrClient][Audio] TCP receive completed")
                self.stop()
                return
            }
            
            self.startReceiveLoop()
        }
    }
    
    private func consumeBufferedPackets() {
        // 协议格式：4字节长度(UInt32, littleEndian) + 8字节时间戳(UInt64, littleEndian) + 音频数据
        let headerSize = 12
        
        while receiveBuffer.count >= headerSize {
            let lengthData = receiveBuffer.subdata(in: 0..<4)
            let timestampData = receiveBuffer.subdata(in: 4..<12)
            
            let payloadLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let timestamp = timestampData.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            let packetSize = headerSize + Int(payloadLength)
            
            guard receiveBuffer.count >= packetSize else {
                return
            }
            
            let payload = receiveBuffer.subdata(in: headerSize..<packetSize)
            receiveBuffer.removeSubrange(0..<packetSize)
            
            resetHeartbeatTimeoutTimer()
            let packet = RGCxrClientAudioPacket(data: payload, timestamp: timestamp)
            delegate?.audioStreamServiceDidReceive(packet: packet)
        }
    }
    
    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        
        delegate?.audioStreamServiceSendPing()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.delegate?.audioStreamServiceSendPing()
        }
        timer.resume()
        heartbeatTimer = timer
    }
    
    private func cancelHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
    
    private func resetHeartbeatTimeoutTimer() {
        cancelHeartbeatTimeoutTimer()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioStreamServiceDidFail(error: NSError(
                domain: "RGCxrClientAudioStreamService",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "心跳超时，音频连接已中断"]
            ))
            self.stop()
        }
        heartbeatTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + heartbeatTimeout, execute: workItem)
    }
    
    private func cancelHeartbeatTimeoutTimer() {
        heartbeatTimeoutWorkItem?.cancel()
        heartbeatTimeoutWorkItem = nil
    }
}
