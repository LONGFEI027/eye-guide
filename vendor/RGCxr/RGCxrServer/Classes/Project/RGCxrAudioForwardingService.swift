import Foundation
import Network
import RGCoreKit

internal protocol RGCxrAudioForwardingDelegate: AnyObject {
    func audioForwardingDidStart(port: UInt16, codec: Int32, type: String, channels: UInt32)
    func audioForwardingDidStop()
    func audioForwardingDidConnect(clientBundleId: String)
    func audioForwardingDidDisconnect(clientBundleId: String)
    func audioForwardingHeartbeat()
}

private struct BufferedAudioData {
    let data: Data
    let timestamp: UInt64
}

internal final class RGCxrAudioForwardingService {
    
    internal static let shared = RGCxrAudioForwardingService()
    
    internal weak var delegate: RGCxrAudioForwardingDelegate?
    
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let connectionLock = NSLock()
    
    private var isRunning = false
    private var currentPort: UInt16 = 0
    private var currentCodec: Int32?
    private var currentType: String?
    private var currentChannels: UInt32?
    
    private var bufferedAudioData: [BufferedAudioData] = []
    private let bufferLock = NSLock()
    
    private var timeoutWorkItem: DispatchWorkItem?
    private let timeoutInterval: TimeInterval = 1.0
    
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatInterval: TimeInterval = 10.0
    
    private let audioQueue = DispatchQueue(label: "com.rokid.cxraudio.forwarding", qos: .userInteractive)
    
    private init() {
        RGLog.info("[AudioForwarding] Service initialized")
    }
    
    internal func handleAudioStreamStart(codec: Int32, type: String, channels: UInt32) {
        guard RGCxrSessionManager.shared.activeSession != nil else {
            RGLog.info("[AudioForwarding] No active session, skip starting TCP server")
            return
        }
        
        RGLog.info("[AudioForwarding] Start audio stream - codec: \(codec), type: \(type), channels: \(channels)")
        
        bufferLock.lock()
        bufferedAudioData.removeAll()
        bufferLock.unlock()
        
        currentCodec = codec
        currentType = type
        currentChannels = channels
        
        startTimeoutTimer()
        startTCPServer()
    }
    
    internal func handleAudioStreamData(data: Data, timestamp: UInt64) {
        guard RGCxrSessionManager.shared.activeSession != nil else {
            return
        }
        
        resetTimeoutTimer()
        
        bufferLock.lock()
        let hasConnections: Bool
        
        connectionLock.lock()
        hasConnections = !connections.isEmpty
        connectionLock.unlock()
        
        if !hasConnections {
            bufferedAudioData.append(BufferedAudioData(data: data, timestamp: timestamp))
            RGLog.debug("[AudioForwarding] Buffering audio data, count: \(bufferedAudioData.count)")
            bufferLock.unlock()
            return
        }
        bufferLock.unlock()
        
        forwardAudioData(data, timestamp: timestamp)
    }
    
    private func startTimeoutTimer() {
        cancelTimeoutTimer()
        
        let workItem = DispatchWorkItem { [weak self] in
            RGLog.info("[AudioForwarding] Audio stream timeout, stopping TCP server")
            self?.stopTCPServer()
        }
        
        timeoutWorkItem = workItem
        audioQueue.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
        RGLog.info("[AudioForwarding] Timeout timer started (\(timeoutInterval)s)")
    }
    
    private func resetTimeoutTimer() {
        cancelTimeoutTimer()
        startTimeoutTimer()
    }
    
    private func cancelTimeoutTimer() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }
    
    private func startHeartbeat() {
        stopHeartbeat()
        
        sendHeartbeat()
        
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
        
        RGLog.info("[AudioForwarding] Heartbeat timer started (\(heartbeatInterval)s)")
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        RGLog.info("[AudioForwarding] Heartbeat timer stopped")
    }
    
    private func sendHeartbeat() {
        delegate?.audioForwardingHeartbeat()

    }
    
    internal func startTCPServer() {
        guard !isRunning else {
            RGLog.info("[AudioForwarding] TCP server already running on port \(currentPort)")
            return
        }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            RGLog.error("[AudioForwarding] Failed to create NWListener: \(error)")
            return
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self = self,
                      let port = self.listener?.port?.rawValue,
                      let codec = currentCodec,
                      let channels = currentChannels,
                      let type = currentType
                else { return }
                self.isRunning = true
                self.currentPort = port
                RGLog.info("[AudioForwarding] TCP server started on port \(port)")
                self.delegate?.audioForwardingDidStart(port: port, codec: codec, type: type, channels: channels)
                
            case .failed(let error):
                RGLog.error("[AudioForwarding] TCP server failed: \(error)")
                self?.stopTCPServer()
                
            case .cancelled:
                RGLog.info("[AudioForwarding] TCP server cancelled")
                self?.isRunning = false
                
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: audioQueue)
    }
    
    internal func stopTCPServer() {
        guard isRunning else { return }
        
        cancelTimeoutTimer()
        stopHeartbeat()
        
        connectionLock.lock()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        connectionLock.unlock()
        
        bufferLock.lock()
        bufferedAudioData.removeAll()
        bufferLock.unlock()
        
        listener?.cancel()
        listener = nil
        isRunning = false
        currentPort = 0
        
        RGLog.info("[AudioForwarding] TCP server stopped")
        delegate?.audioForwardingDidStop()
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                RGLog.info("[AudioForwarding] Client connected: \(connection.endpoint)")
                self?.addConnection(connection)
                if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
                    self?.delegate?.audioForwardingDidConnect(clientBundleId: bundleId)
                }
                self?.sendBufferedData()
                self?.startHeartbeat()
                
            case .failed(let error):
                RGLog.error("[AudioForwarding] Connection failed: \(error)")
                self?.removeConnection(connection)
                
            case .cancelled:
                RGLog.info("[AudioForwarding] Connection cancelled")
                self?.removeConnection(connection)
                
            default:
                break
            }
        }
        
        connection.start(queue: audioQueue)
    }
    
    private func addConnection(_ connection: NWConnection) {
        connectionLock.lock()
        connections.append(connection)
        connectionLock.unlock()
    }
    
    private func removeConnection(_ connection: NWConnection) {
        connectionLock.lock()
        connections.removeAll { $0 === connection }
        connectionLock.unlock()
        
        if let bundleId = RGCxrSessionManager.shared.activeSession?.bundleId {
            delegate?.audioForwardingDidDisconnect(clientBundleId: bundleId)
        }
    }
    
    private func sendBufferedData() {
        bufferLock.lock()
        let buffered = bufferedAudioData
        bufferedAudioData.removeAll()
        bufferLock.unlock()
        
        guard !buffered.isEmpty else {
            RGLog.info("[AudioForwarding] No buffered data to send")
            return
        }
        
        RGLog.info("[AudioForwarding] Sending buffered data: \(buffered.count) audio packets")
        
        for bufferedData in buffered {
            forwardAudioData(bufferedData.data, timestamp: bufferedData.timestamp)
        }
    }
    
    private func forwardAudioData(_ data: Data, timestamp: UInt64) {
        connectionLock.lock()
        let activeConnections = connections
        connectionLock.unlock()
        
        guard !activeConnections.isEmpty else { return }
        
        var headerData = Data()
        let length = UInt32(data.count)
        headerData.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        headerData.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })
        
        let packetData = headerData + data
        
        for connection in activeConnections {
            connection.send(content: packetData, completion: .contentProcessed { error in
                if let error = error {
                    RGLog.error("[AudioForwarding] Send error: \(error)")
                }
            })
        }
    }
}
