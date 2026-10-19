import Foundation
import Network
import RGCoreKit

internal protocol RGCxrClientPhotoStreamServiceDelegate: AnyObject {
    func photoStreamServiceDidConnect(port: UInt16)
    func photoStreamServiceDidReceive(photoData: Data)
    func photoStreamServiceDidStop()
    func photoStreamServiceDidFail(error: Error)
    func photoStreamServiceSendPing()
}

/// 接收 Server -> Client 的照片数据（一次完整图片）
/// 协议：4字节长度(UInt32, littleEndian) + payload(图片二进制)
internal final class RGCxrClientPhotoStreamService {
    
    private enum PhotoStreamServiceError: LocalizedError {
        case invalidPort(UInt16)
        case invalidPacket
        
        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "无效的照片端口: \(port)"
            case .invalidPacket:
                return "无效的照片数据包"
            }
        }
    }
    
    internal weak var delegate: RGCxrClientPhotoStreamServiceDelegate?
    
    private let queue = DispatchQueue(label: "com.rokid.cxr.client.photo", qos: .userInitiated)
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var expectedLength: Int?
    
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatTimeoutWorkItem: DispatchWorkItem?
    
    private let heartbeatInterval: TimeInterval = 10.0
    private let heartbeatTimeout: TimeInterval = 25.0
    private var isStopping = false
    
    internal func start(port: UInt16) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopInternal(notify: false)
            
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.delegate?.photoStreamServiceDidFail(error: PhotoStreamServiceError.invalidPort(port))
                return
            }
            
            self.receiveBuffer.removeAll()
            self.expectedLength = nil
            
            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            self.connection = connection
            
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    RGLog.info("[CxrClient][Photo] TCP connected, port: \(port)")
                    self.delegate?.photoStreamServiceDidConnect(port: port)
                    self.startReceiveLoop()
                    self.startHeartbeatTimer()
                    self.resetHeartbeatTimeoutTimer()
                case .failed(let error):
                    RGLog.error("[CxrClient][Photo] TCP failed: \(error)")
                    self.delegate?.photoStreamServiceDidFail(error: error)
                    self.stop()
                case .cancelled:
                    RGLog.info("[CxrClient][Photo] TCP cancelled")
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
        expectedLength = nil
        
        if notify && hadConnection {
            delegate?.photoStreamServiceDidStop()
        }
        isStopping = false
    }
    
    private func startReceiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard self.connection != nil else { return }
            
            if let error = error {
                self.delegate?.photoStreamServiceDidFail(error: error)
                self.stop()
                return
            }
            
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeBufferedDataIfPossible()
            }
            
            if isComplete {
                RGLog.info("[CxrClient][Photo] TCP receive completed")
                self.stop()
                return
            }
            
            self.startReceiveLoop()
        }
    }
    
    private func consumeBufferedDataIfPossible() {
        let headerSize = 4
        
        if expectedLength == nil {
            guard receiveBuffer.count >= headerSize else { return }
            let lengthData = receiveBuffer.subdata(in: 0..<4)
            let payloadLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            expectedLength = Int(payloadLength)
            receiveBuffer.removeSubrange(0..<4)
        }
        
        guard let expectedLength else { return }
        guard receiveBuffer.count >= expectedLength else { return }
        
        let payload = receiveBuffer.subdata(in: 0..<expectedLength)
        receiveBuffer.removeSubrange(0..<expectedLength)
        
        resetHeartbeatTimeoutTimer()
        delegate?.photoStreamServiceDidReceive(photoData: payload)
        stop()
    }
    
    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        
        delegate?.photoStreamServiceSendPing()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.delegate?.photoStreamServiceSendPing()
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
            self.delegate?.photoStreamServiceDidFail(error: NSError(
                domain: "RGCxrClientPhotoStreamService",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "心跳超时，照片连接已中断"]
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

