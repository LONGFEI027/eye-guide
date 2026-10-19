import Foundation
import Network
import RGCoreKit

internal protocol RGCxrApkUploadDelegate: AnyObject {
    func apkUploadDidStart(requestId: Int, port: UInt16, metadata: [String: Any])
    func apkUploadDidFinish(requestId: Int, success: Bool, localPath: String?)
    func apkUploadDidStop(requestId: Int?)
    func apkUploadHeartbeat()
}

/// Client -> Server APK 上传服务
/// 协议：4字节长度(UInt32, littleEndian) + payload(apk binary)
internal final class RGCxrApkUploadService {
    
    internal static let shared = RGCxrApkUploadService()
    internal weak var delegate: RGCxrApkUploadDelegate?
    
    private let queue = DispatchQueue(label: "com.rokid.cxr.server.apkUpload", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var currentRequestId: Int?
    private var currentFileName: String?
    
    private init() {}
    
    internal func prepare(requestId: Int, fileName: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopInternal(notify: false)
            
            self.currentRequestId = requestId
            self.currentFileName = fileName
            
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        let metadata: [String: Any] = ["requestId": requestId, "fileName": fileName]
                        self.delegate?.apkUploadDidStart(requestId: requestId, port: port.rawValue, metadata: metadata)
                        self.startHeartbeatTimer()
                        RGLog.info("[CxrServer][ApkUpload] listener ready, requestId: \(requestId), port: \(port.rawValue)")
                    case .failed(let error):
                        RGLog.error("[CxrServer][ApkUpload] listener failed: \(error)")
                        self.finish(requestId: requestId, success: false, localPath: nil)
                    case .cancelled:
                        RGLog.info("[CxrServer][ApkUpload] listener cancelled")
                    default:
                        break
                    }
                }
                
                listener.newConnectionHandler = { [weak self] newConnection in
                    self?.accept(newConnection)
                }
                
                listener.start(queue: self.queue)
            } catch {
                RGLog.error("[CxrServer][ApkUpload] create listener failed: \(error)")
                self.finish(requestId: requestId, success: false, localPath: nil)
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
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receiveLengthHeader()
            case .failed(let error):
                RGLog.error("[CxrServer][ApkUpload] connection failed: \(error)")
                self.finish(requestId: self.currentRequestId, success: false, localPath: nil)
            case .cancelled:
                RGLog.info("[CxrServer][ApkUpload] connection cancelled")
            default:
                break
            }
        }
        
        newConnection.start(queue: queue)
    }
    
    private func receiveLengthHeader() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error {
                RGLog.error("[CxrServer][ApkUpload] receive header failed: \(error)")
                self.finish(requestId: self.currentRequestId, success: false, localPath: nil)
                return
            }
            if isComplete {
                self.finish(requestId: self.currentRequestId, success: false, localPath: nil)
                return
            }
            guard let data, data.count == 4 else {
                self.finish(requestId: self.currentRequestId, success: false, localPath: nil)
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
            guard let self = self else { return }
            if let error {
                RGLog.error("[CxrServer][ApkUpload] receive payload failed: \(error)")
                self.finish(requestId: self.currentRequestId, success: false, localPath: nil)
                return
            }
            guard let data, data.count == length else {
                self.finish(requestId: self.currentRequestId, success: false, localPath: nil)
                return
            }
            
            let localPath = self.saveToLocal(data: data)
            self.finish(requestId: self.currentRequestId, success: localPath != nil, localPath: localPath)
        }
    }
    
    private func saveToLocal(data: Data) -> String? {
        let fileName = (currentFileName?.isEmpty == false) ? currentFileName! : "upload.apk"
        let documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folderURL = documentDir.appendingPathComponent("CxrApkUploads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970)
            let finalURL = folderURL.appendingPathComponent("\(timestamp)_\(fileName)")
            try data.write(to: finalURL, options: .atomic)
            RGLog.info("[CxrServer][ApkUpload] saved apk: \(finalURL.path), size: \(data.count)")
            return finalURL.path
        } catch {
            RGLog.error("[CxrServer][ApkUpload] save apk failed: \(error)")
            return nil
        }
    }
    
    private func finish(requestId: Int?, success: Bool, localPath: String?) {
        delegate?.apkUploadDidFinish(requestId: requestId ?? -1, success: success, localPath: localPath)
        stopInternal(notify: true)
    }
    
    private func stopInternal(notify: Bool) {
        let requestId = currentRequestId
        cancelHeartbeatTimer()
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        currentRequestId = nil
        currentFileName = nil
        if notify {
            delegate?.apkUploadDidStop(requestId: requestId)
        }
    }
    
    private func startHeartbeatTimer() {
        cancelHeartbeatTimer()
        delegate?.apkUploadHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.delegate?.apkUploadHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }
    
    private func cancelHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

