import Foundation
import Network
import RGCoreKit

internal protocol RGCxrCustomCmdStreamUploadDelegate: AnyObject {
    func customCmdStreamUploadDidStart(requestId: Int, port: UInt16, metadata: [String: Any])
    func customCmdStreamUploadDidReceive(requestId: Int, cmd: String, payload: Data?, stream: Data)
    func customCmdStreamUploadDidStop(requestId: Int?)
    func customCmdStreamUploadHeartbeat()
}

/// Client -> Server 自定义命令大数据上传服务。
/// 协议：4 字节长度(UInt32, littleEndian) + stream payload。
internal final class RGCxrCustomCmdStreamUploadService {

    internal static let shared = RGCxrCustomCmdStreamUploadService()
    internal weak var delegate: RGCxrCustomCmdStreamUploadDelegate?

    private let queue = DispatchQueue(label: "com.rokid.cxrserver.customCmdStream", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var currentRequestId: Int?
    private var currentCmd: String?
    private var currentPayload: Data?

    private init() {}

    internal func prepare(requestId: Int, cmd: String, payload: Data?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(notify: false)

            self.currentRequestId = requestId
            self.currentCmd = cmd
            self.currentPayload = payload

            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        let metadata: [String: Any] = ["requestId": requestId, "cmd": cmd]
                        self.delegate?.customCmdStreamUploadDidStart(
                            requestId: requestId,
                            port: port.rawValue,
                            metadata: metadata
                        )
                        self.startHeartbeatTimer()
                        RGLog.info("[CxrServer][CustomCmdStream] listener ready, requestId: \(requestId), port: \(port.rawValue)")
                    case .failed(let error):
                        RGLog.error("[CxrServer][CustomCmdStream] listener failed: \(error)")
                        self.stopInternal(notify: true)
                    case .cancelled:
                        RGLog.info("[CxrServer][CustomCmdStream] listener cancelled")
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] newConnection in
                    self?.accept(newConnection)
                }

                listener.start(queue: self.queue)
            } catch {
                RGLog.error("[CxrServer][CustomCmdStream] create listener failed: \(error)")
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
                RGLog.error("[CxrServer][CustomCmdStream] connection failed: \(error)")
                self.stopInternal(notify: true)
            case .cancelled:
                RGLog.info("[CxrServer][CustomCmdStream] connection cancelled")
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
                RGLog.error("[CxrServer][CustomCmdStream] receive header failed: \(error)")
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
            self.receivePayload(length: Int(payloadLength))
        }
    }

    private func receivePayload(length: Int) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                RGLog.error("[CxrServer][CustomCmdStream] receive payload failed: \(error)")
                self.stopInternal(notify: true)
                return
            }
            guard let data,
                  data.count == length,
                  let requestId = self.currentRequestId,
                  let cmd = self.currentCmd else {
                self.stopInternal(notify: true)
                return
            }

            self.delegate?.customCmdStreamUploadDidReceive(
                requestId: requestId,
                cmd: cmd,
                payload: self.currentPayload,
                stream: data
            )
            self.stopInternal(notify: true)
        }
    }

    private func stopInternal(notify: Bool) {
        let requestId = currentRequestId
        cancelHeartbeatTimer()
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        currentRequestId = nil
        currentCmd = nil
        currentPayload = nil
        if notify {
            delegate?.customCmdStreamUploadDidStop(requestId: requestId)
        }
    }

    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        delegate?.customCmdStreamUploadHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.delegate?.customCmdStreamUploadHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func cancelHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}
