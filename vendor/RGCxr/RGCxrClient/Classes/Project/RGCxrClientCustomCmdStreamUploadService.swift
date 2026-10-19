import Foundation
import Network
import RGCoreKit

internal protocol RGCxrClientCustomCmdStreamUploadServiceDelegate: AnyObject {
    func customCmdStreamUploadServiceDidConnect(requestId: Int, port: UInt16)
    func customCmdStreamUploadServiceDidSend(requestId: Int)
    func customCmdStreamUploadServiceDidStop()
    func customCmdStreamUploadServiceDidFail(requestId: Int, error: Error)
    func customCmdStreamUploadServiceSendPing()
}

/// Client -> Server 自定义命令 stream 上传。
/// 协议：4 字节长度(UInt32, littleEndian) + stream payload。
internal final class RGCxrClientCustomCmdStreamUploadService {

    private enum UploadError: LocalizedError {
        case invalidPort(UInt16)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "无效的自定义命令上传端口: \(port)"
            }
        }
    }

    internal weak var delegate: RGCxrClientCustomCmdStreamUploadServiceDelegate?

    private let queue = DispatchQueue(label: "com.rokid.cxr.client.customCmdStream", qos: .userInitiated)
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatTimeoutWorkItem: DispatchWorkItem?
    private let heartbeatInterval: TimeInterval = 10.0
    private let heartbeatTimeout: TimeInterval = 25.0
    private var isStopping = false

    internal func start(requestId: Int, port: UInt16, stream: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(notify: false)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.delegate?.customCmdStreamUploadServiceDidFail(requestId: requestId, error: UploadError.invalidPort(port))
                return
            }

            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    RGLog.info("[CxrClient][CustomCmdStream] TCP connected, port: \(port), requestId: \(requestId)")
                    self.delegate?.customCmdStreamUploadServiceDidConnect(requestId: requestId, port: port)
                    self.startHeartbeatTimer()
                    self.resetHeartbeatTimeoutTimer()
                    self.sendPayload(requestId: requestId, stream: stream)
                case .failed(let error):
                    RGLog.error("[CxrClient][CustomCmdStream] TCP failed: \(error)")
                    self.delegate?.customCmdStreamUploadServiceDidFail(requestId: requestId, error: error)
                    self.stop()
                case .cancelled:
                    RGLog.info("[CxrClient][CustomCmdStream] TCP cancelled")
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
            guard let self, self.connection != nil else { return }
            self.resetHeartbeatTimeoutTimer()
        }
    }

    private func sendPayload(requestId: Int, stream: Data) {
        guard let connection else { return }
        let length = UInt32(stream.count)
        var packet = Data()
        packet.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        packet.append(stream)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.delegate?.customCmdStreamUploadServiceDidFail(requestId: requestId, error: error)
            } else {
                self.delegate?.customCmdStreamUploadServiceDidSend(requestId: requestId)
            }
        })
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
            delegate?.customCmdStreamUploadServiceDidStop()
        }
        isStopping = false
    }

    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        delegate?.customCmdStreamUploadServiceSendPing()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.delegate?.customCmdStreamUploadServiceSendPing()
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
            self?.stop()
        }
        heartbeatTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + heartbeatTimeout, execute: workItem)
    }

    private func cancelHeartbeatTimeoutTimer() {
        heartbeatTimeoutWorkItem?.cancel()
        heartbeatTimeoutWorkItem = nil
    }
}
