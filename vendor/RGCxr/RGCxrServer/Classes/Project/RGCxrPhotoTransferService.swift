import Foundation
import Network
import RGCoreKit

internal protocol RGCxrPhotoTransferDelegate: AnyObject {
    func photoTransferDidStart(port: UInt16, metadata: [String: Any])
    func photoTransferDidStop()
    func photoTransferHeartbeat()
}

/// Server -> Client 照片数据传输（一次完整图片）
/// 协议：4字节长度(UInt32, littleEndian) + payload(图片二进制)
internal final class RGCxrPhotoTransferService {
    
    internal static let shared = RGCxrPhotoTransferService()
    
    internal weak var delegate: RGCxrPhotoTransferDelegate?
    
    private let queue = DispatchQueue(label: "com.rokid.cxrserver.photoTransfer", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    
    private var pendingPhotoData: Data?
    private var pendingMetadata: [String: Any]?
    
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatInterval: TimeInterval = 10.0
    
    private init() {}
    
    internal func prepare(metadata: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pendingMetadata = metadata
            self.startTCPServerIfNeeded()
        }
    }
    
    internal func onPhotoDataReady(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.connection == nil {
                self.pendingPhotoData = data
                RGLog.info("[PhotoTransfer] 缓存照片数据，等待客户端连接，size: \(data.count)")
                return
            }
            self.sendPhotoData(data)
        }
    }
    
    private func startTCPServerIfNeeded() {
        guard listener == nil else { return }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            RGLog.error("[PhotoTransfer] Failed to create NWListener: \(error)")
            return
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                guard let port = self.listener?.port?.rawValue else { return }
                let metadata = self.pendingMetadata ?? [:]
                RGLog.info("[PhotoTransfer] TCP server started on port \(port)")
                self.delegate?.photoTransferDidStart(port: port, metadata: metadata)
            case .failed(let error):
                RGLog.error("[PhotoTransfer] TCP server failed: \(error)")
                self.stop()
            case .cancelled:
                RGLog.info("[PhotoTransfer] TCP server cancelled")
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
        
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                RGLog.info("[PhotoTransfer] Client connected: \(conn.endpoint)")
                self.startHeartbeat()
                if let pending = self.pendingPhotoData {
                    self.pendingPhotoData = nil
                    self.sendPhotoData(pending)
                }
            case .failed(let error):
                RGLog.error("[PhotoTransfer] Connection failed: \(error)")
                self.stop()
            case .cancelled:
                RGLog.info("[PhotoTransfer] Connection cancelled")
                self.stop()
            default:
                break
            }
        }
        
        conn.start(queue: queue)
    }
    
    private func sendPhotoData(_ data: Data) {
        guard let connection else {
            pendingPhotoData = data
            return
        }
        let length = UInt32(data.count)
        var packet = Data()
        packet.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        packet.append(data)
        
        RGLog.info("[PhotoTransfer] 发送照片数据 size: \(data.count)")
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error = error {
                RGLog.error("[PhotoTransfer] Send error: \(error)")
            }
            self?.stop()
        })
    }
    
    internal func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopHeartbeat()
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.pendingPhotoData = nil
            self.pendingMetadata = nil
            self.delegate?.photoTransferDidStop()
        }
    }
    
    private func startHeartbeat() {
        stopHeartbeat()
        delegate?.photoTransferHeartbeat()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.delegate?.photoTransferHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

