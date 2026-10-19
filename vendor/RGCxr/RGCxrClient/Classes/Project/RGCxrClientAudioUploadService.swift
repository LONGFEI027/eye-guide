import Foundation
import Network
import RGCoreKit

internal protocol RGCxrClientAudioUploadServiceDelegate: AnyObject {
    func audioUploadServiceDidConnect(port: UInt16)
    func audioUploadServiceDidStop()
    func audioUploadServiceDidFail(error: Error)
    func audioUploadServiceSendPing()
}

/// Client -> Server 音频上传
/// 协议：4字节长度(UInt32, littleEndian) + payload(PCM/编码后音频数据)
internal final class RGCxrClientAudioUploadService {
    
    private enum AudioUploadServiceError: LocalizedError {
        case invalidPort(UInt16)
        
        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "无效的音频上传端口: \(port)"
            }
        }
    }
    
    internal weak var delegate: RGCxrClientAudioUploadServiceDelegate?
    
    private let queue = DispatchQueue(label: "com.rokid.cxr.client.audioUpload", qos: .userInitiated)
    private var connection: NWConnection?
    
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
                self.delegate?.audioUploadServiceDidFail(error: AudioUploadServiceError.invalidPort(port))
                return
            }
            
            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            self.connection = connection
            
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    RGLog.info("[CxrClient][AudioUp] TCP connected, port: \(port)")
                    self.delegate?.audioUploadServiceDidConnect(port: port)
                    self.startHeartbeatTimer()
                    self.resetHeartbeatTimeoutTimer()
                case .failed(let error):
                    RGLog.error("[CxrClient][AudioUp] TCP failed: \(error)")
                    self.delegate?.audioUploadServiceDidFail(error: error)
                    self.stop()
                case .cancelled:
                    RGLog.info("[CxrClient][AudioUp] TCP cancelled")
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
    
    internal func sendAudio(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self, let connection = self.connection else { return }
            let length = UInt32(data.count)
            var packet = Data()
            packet.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
            packet.append(data)
            
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    RGLog.error("[CxrClient][AudioUp] send error: \(error)")
                }
            })
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
        
        if notify && hadConnection {
            delegate?.audioUploadServiceDidStop()
        }
        isStopping = false
    }
    
    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        
        delegate?.audioUploadServiceSendPing()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.delegate?.audioUploadServiceSendPing()
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
            self.delegate?.audioUploadServiceDidFail(error: NSError(
                domain: "RGCxrClientAudioUploadService",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "心跳超时，音频上传连接已中断"]
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

