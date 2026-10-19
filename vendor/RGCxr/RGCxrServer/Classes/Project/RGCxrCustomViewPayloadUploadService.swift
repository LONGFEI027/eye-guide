import Foundation
import Network
import RGCoreKit

internal enum RGCxrCustomViewPayloadOperation: String {
    case sendIcons
    case open
    case update
}

internal protocol RGCxrCustomViewPayloadUploadDelegate: AnyObject {
    func customViewPayloadUploadDidStart(requestId: Int, port: UInt16, metadata: [String: Any])
    func customViewPayloadUploadDidReceive(requestId: Int, operation: RGCxrCustomViewPayloadOperation, text: String)
    /// TCP 收包失败、解码失败或连接中断且未完成收包时回调（此时尚未调用 `RGCxrCustomViewService`）。
    func customViewPayloadUploadDidAbort(requestId: Int, operation: RGCxrCustomViewPayloadOperation)
    func customViewPayloadUploadDidStop(requestId: Int?)
    func customViewPayloadUploadHeartbeat()
}

/// Client → Server 自定义 View 大文本（icons / view）上传。
/// 协议：4 字节长度(UInt32, littleEndian) + UTF-8 文本 body（与 `custom_cmd_upload` 一致）。
internal final class RGCxrCustomViewPayloadUploadService {

    internal static let shared = RGCxrCustomViewPayloadUploadService()
    internal weak var delegate: RGCxrCustomViewPayloadUploadDelegate?

    private let queue = DispatchQueue(label: "com.rokid.cxrserver.customViewPayload", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var currentRequestId: Int?
    private var currentOperation: RGCxrCustomViewPayloadOperation?
    private var hasDeliveredPayload = false

    private let maxPayloadBytes = 32 * 1024 * 1024

    private init() {}

    internal func prepare(requestId: Int, operation: RGCxrCustomViewPayloadOperation) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(notify: false)

            self.currentRequestId = requestId
            self.currentOperation = operation
            self.hasDeliveredPayload = false

            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        let metadata: [String: Any] = [
                            "requestId": requestId,
                            "op": operation.rawValue
                        ]
                        self.delegate?.customViewPayloadUploadDidStart(
                            requestId: requestId,
                            port: port.rawValue,
                            metadata: metadata
                        )
                        self.startHeartbeatTimer()
                        RGLog.info("[CxrServer][CustomViewPayload] listener ready, requestId: \(requestId), op: \(operation.rawValue), port: \(port.rawValue)")
                    case .failed(let error):
                        RGLog.error("[CxrServer][CustomViewPayload] listener failed: \(error)")
                        self.stopInternal(notify: true)
                    case .cancelled:
                        RGLog.info("[CxrServer][CustomViewPayload] listener cancelled")
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] newConnection in
                    self?.accept(newConnection)
                }

                listener.start(queue: self.queue)
            } catch {
                RGLog.error("[CxrServer][CustomViewPayload] create listener failed: \(error)")
                self.stopInternal(notify: true)
            }
        }
    }

    internal func stop() {
        queue.async { [weak self] in
            self?.stopInternal(notify: true)
        }
    }

    private func accept(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection

        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLengthHeader()
            case .failed(let error):
                RGLog.error("[CxrServer][CustomViewPayload] connection failed: \(error)")
                self.stopInternal(notify: true)
            case .cancelled:
                RGLog.info("[CxrServer][CustomViewPayload] connection cancelled")
            default:
                break
            }
        }

        newConnection.start(queue: queue)
    }

    private func receiveLengthHeader() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                RGLog.error("[CxrServer][CustomViewPayload] receive header failed: \(error)")
                self.stopInternal(notify: true)
                return
            }
            if isComplete {
                self.stopInternal(notify: true)
                return
            }
            guard let data, data.count == 4 else {
                self.stopInternal(notify: true)
                return
            }
            let payloadLength = data.withUnsafeBytes { rawBuffer in
                rawBuffer.load(as: UInt32.self).littleEndian
            }
            let length = Int(payloadLength)
            guard length >= 0, length <= self.maxPayloadBytes else {
                RGLog.error("[CxrServer][CustomViewPayload] invalid payload length: \(length)")
                self.stopInternal(notify: true)
                return
            }
            self.receivePayload(length: length)
        }
    }

    private func receivePayload(length: Int) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                RGLog.error("[CxrServer][CustomViewPayload] receive payload failed: \(error)")
                self.stopInternal(notify: true)
                return
            }
            guard let data,
                  data.count == length,
                  let requestId = self.currentRequestId,
                  let operation = self.currentOperation else {
                self.stopInternal(notify: true)
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                RGLog.error("[CxrServer][CustomViewPayload] UTF-8 解码失败, requestId: \(requestId)")
                self.stopInternal(notify: true)
                return
            }

            self.hasDeliveredPayload = true
            self.delegate?.customViewPayloadUploadDidReceive(
                requestId: requestId,
                operation: operation,
                text: text
            )
            self.stopInternal(notify: true)
        }
    }

    private func stopInternal(notify: Bool) {
        if notify,
           let requestId = currentRequestId,
           let operation = currentOperation,
           !hasDeliveredPayload {
            delegate?.customViewPayloadUploadDidAbort(requestId: requestId, operation: operation)
        }

        let requestId = currentRequestId
        cancelHeartbeatTimer()
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        currentRequestId = nil
        currentOperation = nil
        hasDeliveredPayload = false
        if notify {
            delegate?.customViewPayloadUploadDidStop(requestId: requestId)
        }
    }

    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        delegate?.customViewPayloadUploadHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.delegate?.customViewPayloadUploadHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func cancelHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}
