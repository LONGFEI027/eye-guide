import Foundation
import Network
import RGCoreKit
import RGCxrKit

internal protocol RGCxrAudioPlaybackDelegate: AnyObject {
    func audioPlaybackDidStart(port: UInt16, metadata: [String: Any])
    func audioPlaybackDidStop()
    func audioPlaybackHeartbeat()
}

/// Server 端真实音频播放服务：接收 Client -> Server 的音频流并喂给 RGSocketAudioPlayer
/// 协议：4字节长度(UInt32, littleEndian) + payload
internal final class RGCxrAudioPlaybackService {
    
    internal static let shared = RGCxrAudioPlaybackService()
    internal weak var delegate: RGCxrAudioPlaybackDelegate?
    
    private let queue = DispatchQueue(label: "com.rokid.cxrserver.audioPlayback", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    
    private var receiveBuffer = Data()
    private var expectedLength: Int?
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatInterval: TimeInterval = 10.0
    
    private var pendingMetadata: [String: Any]?
    private var currentCodec: RGCxrAudioCodec = .pcm
    private var currentStreamId: Int = 910001
    
    private init() {}
    
    internal func start(metadata: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pendingMetadata = metadata
            if let codecRaw = metadata["codec"] as? UInt32,
               let codec = RGCxrAudioCodec(rawValue: codecRaw) {
                self.currentCodec = codec
            } else if let codecInt = metadata["codec"] as? Int,
                      let codec = RGCxrAudioCodec(rawValue: UInt32(codecInt)) {
                self.currentCodec = codec
            } else {
                self.currentCodec = .pcm
            }
            let stream = switch self.currentCodec {
            case .pcm:
                RGSocketAudioPlayer.shared.playAudio(codec: .pcm)
            case .oggOpus:
                RGSocketAudioPlayer.shared.playAudio(codec: .oggOpus)
            case .mp3:
                RGSocketAudioPlayer.shared.playAudio(codec: .mp3)
            }
            if let stream = stream {
                self.currentStreamId = stream.streamId
            }
            self.startListenerIfNeeded()
        }
    }
    
    private func startListenerIfNeeded() {
        guard listener == nil else { return }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            RGLog.error("[AudioPlayback] Failed to create NWListener: \(error)")
            return
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                guard let port = self.listener?.port?.rawValue else { return }
                let metadata = self.pendingMetadata ?? [:]
                RGLog.info("[AudioPlayback] TCP server started on port \(port)")
                self.delegate?.audioPlaybackDidStart(port: port, metadata: metadata)
            case .failed(let error):
                RGLog.error("[AudioPlayback] TCP server failed: \(error)")
                self.stop()
            case .cancelled:
                RGLog.info("[AudioPlayback] TCP server cancelled")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        
        listener?.start(queue: queue)
    }
    
    private func handleNewConnection(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        receiveBuffer.removeAll()
        expectedLength = nil
        
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                RGLog.info("[AudioPlayback] Client connected: \(conn.endpoint), codec: \(self.currentCodec.rawValue)")
                self.startHeartbeat()
                self.startReceiveLoop()
            case .failed(let error):
                RGLog.error("[AudioPlayback] Connection failed: \(error)")
                self.stop()
            case .cancelled:
                RGLog.info("[AudioPlayback] Connection cancelled")
                self.stop()
            default:
                break
            }
        }
        
        conn.start(queue: queue)
    }
    
    private func startReceiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                RGLog.error("[AudioPlayback] receive error: \(error)")
                self.stop()
                return
            }
            
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumePackets()
            }
            
            if isComplete {
                RGLog.info("[AudioPlayback] receive completed")
                self.stop()
                return
            }
            
            self.startReceiveLoop()
        }
    }
    
    private func consumePackets() {
        let headerSize = 4
        
        while true {
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
            self.expectedLength = nil
            
            switch currentCodec {
            case .pcm:
                RGSocketAudioPlayer.shared.sendAudio(id: currentStreamId, data: payload, codec: .pcm)
            case .oggOpus:
                RGSocketAudioPlayer.shared.sendAudio(id: currentStreamId, data: payload, codec: .oggOpus)
            case .mp3:
                RGSocketAudioPlayer.shared.sendAudio(id: currentStreamId, data: payload, codec: .mp3)
            }
        }
    }
    
    internal func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopHeartbeat()
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.pendingMetadata = nil
            self.receiveBuffer.removeAll()
            self.expectedLength = nil
            RGSocketAudioPlayer.shared.stopPlayAudio(id: self.currentStreamId)
            self.delegate?.audioPlaybackDidStop()
        }
    }
    
    private func startHeartbeat() {
        stopHeartbeat()
        delegate?.audioPlaybackHeartbeat()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.delegate?.audioPlaybackHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

