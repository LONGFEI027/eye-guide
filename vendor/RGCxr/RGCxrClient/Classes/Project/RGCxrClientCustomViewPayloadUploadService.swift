import Foundation
import Network
import RGCoreKit

internal protocol RGCxrClientCustomViewPayloadUploadServiceDelegate: AnyObject {
    func customViewPayloadUploadServiceDidConnect(requestId: Int, port: UInt16)
    func customViewPayloadUploadServiceDidSend(requestId: Int)
    func customViewPayloadUploadServiceDidStop()
    func customViewPayloadUploadServiceDidFail(requestId: Int, error: Error)
    func customViewPayloadUploadServiceSendPing()
}

/// Client → Server 自定义 View 大文本上传（icons / view）。
/// 协议：4 字节长度(UInt32, littleEndian) + UTF-8 body。
internal final class RGCxrClientCustomViewPayloadUploadService {

    private enum UploadError: LocalizedError {
        case invalidPort(UInt16)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "无效的自定义 View 上传端口: \(port)"
            }
        }
    }

    internal weak var delegate: RGCxrClientCustomViewPayloadUploadServiceDelegate?

    private let queue = DispatchQueue(label: "com.rokid.cxr.client.customViewPayload", qos: .userInitiated)
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatTimeoutWorkItem: DispatchWorkItem?
    private let heartbeatInterval: TimeInterval = 10.0
    private let heartbeatTimeout: TimeInterval = 25.0
    private var isStopping = false

    internal func start(requestId: Int, port: UInt16, payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(notify: false)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.delegate?.customViewPayloadUploadServiceDidFail(requestId: requestId, error: UploadError.invalidPort(port))
                return
            }

            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    RGLog.info("[CxrClient][CustomViewPayload] TCP connected, port: \(port), requestId: \(requestId)")
                    self.delegate?.customViewPayloadUploadServiceDidConnect(requestId: requestId, port: port)
                    self.startHeartbeatTimer()
                    self.resetHeartbeatTimeoutTimer()
                    self.sendPayload(requestId: requestId, payload: payload)
                case .failed(let error):
                    RGLog.error("[CxrClient][CustomViewPayload] TCP failed: \(error)")
                    self.delegate?.customViewPayloadUploadServiceDidFail(requestId: requestId, error: error)
                    self.stop()
                case .cancelled:
                    RGLog.info("[CxrClient][CustomViewPayload] TCP cancelled")
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

    private func sendPayload(requestId: Int, payload: Data) {
        guard let connection else { return }
        let length = UInt32(payload.count)
        var packet = Data()
        packet.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.delegate?.customViewPayloadUploadServiceDidFail(requestId: requestId, error: error)
            } else {
                self.delegate?.customViewPayloadUploadServiceDidSend(requestId: requestId)
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
            delegate?.customViewPayloadUploadServiceDidStop()
        }
        isStopping = false
    }

    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        delegate?.customViewPayloadUploadServiceSendPing()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.delegate?.customViewPayloadUploadServiceSendPing()
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
