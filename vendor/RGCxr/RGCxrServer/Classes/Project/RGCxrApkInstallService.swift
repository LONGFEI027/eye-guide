import Foundation
import NetworkExtension
import RGCoreKit
import RGCxrKit

private let RTAX_DST = 0
private let RTAX_GATEWAY = 1
private let RTAX_MAX = 8

private struct rt_metrics {
    var rmx_locks: UInt32
    var rmx_mtu: UInt32
    var rmx_hopcount: UInt32
    var rmx_expire: Int32
    var rmx_recvpipe: UInt32
    var rmx_sendpipe: UInt32
    var rmx_ssthresh: UInt32
    var rmx_rtt: UInt32
    var rmx_rttvar: UInt32
    var rmx_pksent: UInt32
    var rmx_state: UInt32
    var rmx_filler: (UInt32, UInt32, UInt32)
}

private struct rt_msghdr2 {
    var rtm_msglen: u_short
    var rtm_version: u_char
    var rtm_type: u_char
    var rtm_index: u_short
    var rtm_flags: Int32
    var rtm_addrs: Int32
    var rtm_refcnt: Int32
    var rtm_parentflags: Int32
    var rtm_reserved: Int32
    var rtm_use: Int32
    var rtm_inits: UInt32
    var rtm_rmx: rt_metrics
}

internal protocol RGCxrApkInstallServiceDelegate: AnyObject {
    func apkInstallServiceDidFinish(requestId: Int, success: Bool)
}

/// 负责将本地 APK 上传到眼镜热点并等待安装结果事件
internal final class RGCxrApkInstallService {
    
    private struct HotspotInfo {
        let ssid: String
        let password: String
        let ip: String?
        let securityType: Int
    }
    
    internal static let shared: RGCxrApkInstallService = {
        RGCxrApkInstallService(startupCleanup: true)
    }()
    internal weak var delegate: RGCxrApkInstallServiceDelegate?
    
    private let queue = DispatchQueue(label: "com.rokid.cxr.server.apkInstall", qos: .userInitiated)
    private let uploadPath = "server/upload"
    private let tempFolderName = "CxrApkUploads"
    private let port = 8848
    private let maxWiFiRetry = 3
    private let maxGatewayRetry = 3
    private let maxUploadRetry = 3
    private let retryDelay: TimeInterval = 2
    private let gatewayPollTimeout: TimeInterval = 6
    private let installTimeout: TimeInterval = 90
    
    private var pendingRequestId: Int?
    private var pendingApkPath: String?
    private var pendingFileName: String?
    private var expectedServerIP: String?
    private var resolvedServerIP: String?
    private var isInstalling = false
    private var installTimeoutWorkItem: DispatchWorkItem?
    
    private init() {}
    
    private init(startupCleanup: Bool) {
        if startupCleanup {
            queue.async { [weak self] in
                self?.cleanupAllTempFiles()
            }
        }
    }
    
    internal func startInstall(requestId: Int, apkPath: String, fileName: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isInstalling else {
                RGLog.warn("[CxrServer][ApkInstall] 当前已有安装任务，忽略新请求 requestId=\(requestId)")
                return
            }
            self.pendingRequestId = requestId
            self.pendingApkPath = apkPath
            self.pendingFileName = fileName
            self.expectedServerIP = nil
            self.resolvedServerIP = nil
            self.isInstalling = true
            self.startInstallTimeout()
            
            RGLog.info("[CxrServer][ApkInstall] 开始请求眼镜热点信息，requestId=\(requestId)")
            RGCxrKit.shared.send(cmd: .Med, subCmd: .Sync_Start, data: ["type": "IOS"].toJsonString())
        }
    }
    
    internal func handleSyncStart(_ responseData: Any?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.isInstalling else { return }
            guard let info = self.parseHotspotInfo(from: responseData) else {
                RGLog.error("[CxrServer][ApkInstall] Sync_Start 数据解析失败: \(String(describing: responseData))")
                self.finish(success: false, stopSync: true)
                return
            }
            self.expectedServerIP = info.ip
            self.connectToHotspot(info: info, retryCount: 0)
        }
    }
    
    internal func handleInstallResult(success: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.isInstalling else { return }
            RGLog.info("[CxrServer][ApkInstall] 收到眼镜安装结果: \(success)")
            self.finish(success: success, stopSync: true)
        }
    }
    
    private func parseHotspotInfo(from responseData: Any?) -> HotspotInfo? {
        guard let jsonString = responseData as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ssid = json["account"] as? String,
              !ssid.isEmpty,
              let password = json["password"] as? String,
              !password.isEmpty else {
            return nil
        }
        let ip = (json["ip"] as? String).flatMap { $0 == "0.0.0.0" ? nil : $0 }
        let securityType = (json["securityType"] as? Int) ?? 0
        return HotspotInfo(ssid: ssid, password: password, ip: ip, securityType: securityType)
    }
    
    private func connectToHotspot(info: HotspotInfo, retryCount: Int) {
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("[CxrServer][ApkInstall] 当前 CXR 未连接，无法连接热点")
            finish(success: false, stopSync: true)
            return
        }
        
        let config = NEHotspotConfiguration(ssid: info.ssid, passphrase: info.password, isWEP: info.securityType == 1)
        config.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                guard self.isInstalling else { return }
                
                if let nsError = error as NSError? {
                    if nsError.code == 13 {
                        RGLog.info("[CxrServer][ApkInstall] 热点已连接，继续获取网关")
                        self.waitForGatewayAndUpload(info: info, gatewayRetry: 0, wifiRetry: retryCount)
                        return
                    }
                    if nsError.code == 7 {
                        RGLog.warn("[CxrServer][ApkInstall] 用户取消热点连接")
                        self.finish(success: false, stopSync: true)
                        return
                    }
                    if retryCount < self.maxWiFiRetry {
                        RGLog.warn("[CxrServer][ApkInstall] 热点连接失败 code=\(nsError.code)，准备重试 \(retryCount + 1)/\(self.maxWiFiRetry)")
                        self.queue.asyncAfter(deadline: .now() + self.retryDelay) { [weak self] in
                            self?.connectToHotspot(info: info, retryCount: retryCount + 1)
                        }
                    } else {
                        RGLog.error("[CxrServer][ApkInstall] 热点连接失败，达到最大重试次数")
                        self.finish(success: false, stopSync: true)
                    }
                } else {
                    RGLog.info("[CxrServer][ApkInstall] 热点连接成功")
                    self.waitForGatewayAndUpload(info: info, gatewayRetry: 0, wifiRetry: retryCount)
                }
            }
        }
    }
    
    private func waitForGatewayAndUpload(info: HotspotInfo, gatewayRetry: Int, wifiRetry: Int) {
        resolveGatewayIP(timeout: gatewayPollTimeout) { [weak self] ip in
            guard let self = self else { return }
            self.queue.async {
                guard self.isInstalling else { return }
                if let ip {
                    self.resolvedServerIP = ip
                    self.uploadApkToServer(ip: ip)
                    return
                }
                
                if gatewayRetry < self.maxGatewayRetry {
                    RGLog.warn("[CxrServer][ApkInstall] 网关未就绪，重试 \(gatewayRetry + 1)/\(self.maxGatewayRetry)")
                    self.queue.asyncAfter(deadline: .now() + self.retryDelay) { [weak self] in
                        self?.waitForGatewayAndUpload(info: info, gatewayRetry: gatewayRetry + 1, wifiRetry: wifiRetry)
                    }
                    return
                }
                
                if wifiRetry < self.maxWiFiRetry {
                    RGLog.warn("[CxrServer][ApkInstall] 网关持续不可用，尝试重连热点 \(wifiRetry + 1)/\(self.maxWiFiRetry)")
                    self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.connectToHotspot(info: info, retryCount: wifiRetry + 1)
                    }
                } else {
                    RGLog.error("[CxrServer][ApkInstall] 网关持续不可用，安装流程失败")
                    self.finish(success: false, stopSync: true)
                }
            }
        }
    }
    
    private func resolveGatewayIP(timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        let start = Date().timeIntervalSince1970
        func poll() {
            if !isInstalling {
                completion(nil)
                return
            }
            if let gateway = getDefaultGateway(), isPrivateIP(gateway) {
                if let expectedIP = expectedServerIP, !expectedIP.isEmpty {
                    // 若眼镜明确下发了 IP，优先等待路由网关与其一致，避免路由尚未切换完成导致 -1009
                    if gateway == expectedIP {
                        completion(gateway)
                        return
                    }
                } else {
                    completion(gateway)
                    return
                }
            }
            if Date().timeIntervalSince1970 - start > timeout {
                // 超时兜底：若拿不到可用网关，才回落到眼镜下发 IP（若有）
                if let expectedIP = expectedServerIP, !expectedIP.isEmpty {
                    completion(expectedIP)
                } else {
                    completion(nil)
                }
                return
            }
            queue.asyncAfter(deadline: .now() + 0.2) {
                poll()
            }
        }
        poll()
    }
    
    private func uploadApkToServer(ip: String, retryCount: Int = 0) {
        guard let requestId = pendingRequestId,
              let apkPath = pendingApkPath,
              let fileName = pendingFileName else {
            finish(success: false, stopSync: true)
            return
        }
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: apkPath)) else {
            RGLog.error("[CxrServer][ApkInstall] 读取本地APK失败: \(apkPath)")
            finish(success: false, stopSync: true)
            return
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"upfile\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/vnd.android.package-archive\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        guard let url = URL(string: "http://\(ip):\(port)/\(uploadPath)") else {
            finish(success: false, stopSync: true)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(RGApplication.version, forHTTPHeaderField: "appVersion")
        request.setValue("1.0", forHTTPHeaderField: "apiVersion")
        
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.allowsCellularAccess = false
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 10 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        
        RGLog.info("[CxrServer][ApkInstall] 开始上传APK，requestId=\(requestId), size=\(fileData.count), url=\(url.absoluteString)")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.isInstalling else { return }
                if let error {
                    let nsError = error as NSError
                    if retryCount < self.maxUploadRetry {
                        RGLog.warn("[CxrServer][ApkInstall] 上传失败，准备重试 \(retryCount + 1)/\(self.maxUploadRetry), code=\(nsError.code), error=\(nsError.localizedDescription)")
                        self.queue.asyncAfter(deadline: .now() + self.retryDelay) { [weak self] in
                            guard let self = self, self.isInstalling else { return }
                            self.resolveGatewayIP(timeout: self.gatewayPollTimeout) { [weak self] newIP in
                                guard let self = self else { return }
                                self.queue.async {
                                    guard self.isInstalling else { return }
                                    guard let newIP else {
                                        self.finish(success: false, stopSync: true)
                                        return
                                    }
                                    self.uploadApkToServer(ip: newIP, retryCount: retryCount + 1)
                                }
                            }
                        }
                    } else {
                        RGLog.error("[CxrServer][ApkInstall] 上传失败: \(nsError.localizedDescription)")
                        self.finish(success: false, stopSync: true)
                    }
                    return
                }
                guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    if retryCount < self.maxUploadRetry {
                        RGLog.warn("[CxrServer][ApkInstall] 上传返回状态异常: \(status)，准备重试 \(retryCount + 1)/\(self.maxUploadRetry)")
                        self.queue.asyncAfter(deadline: .now() + self.retryDelay) { [weak self] in
                            guard let self = self, self.isInstalling else { return }
                            self.resolveGatewayIP(timeout: self.gatewayPollTimeout) { [weak self] newIP in
                                guard let self = self else { return }
                                self.queue.async {
                                    guard self.isInstalling else { return }
                                    guard let newIP else {
                                        self.finish(success: false, stopSync: true)
                                        return
                                    }
                                    self.uploadApkToServer(ip: newIP, retryCount: retryCount + 1)
                                }
                            }
                        }
                    } else {
                        RGLog.error("[CxrServer][ApkInstall] 上传返回状态异常: \(status)")
                        self.finish(success: false, stopSync: true)
                    }
                    return
                }
                RGLog.info("[CxrServer][ApkInstall] 上传成功，等待眼镜安装事件")
                RGCxrKit.shared.send(cmd: .Med, subCmd: .Sync_Stop)
            }
        }.resume()
    }
    
    private func startInstallTimeout() {
        installTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isInstalling else { return }
            RGLog.error("[CxrServer][ApkInstall] 安装结果等待超时")
            self.finish(success: false, stopSync: true)
        }
        installTimeoutWorkItem = item
        queue.asyncAfter(deadline: .now() + installTimeout, execute: item)
    }
    
    private func finish(success: Bool, stopSync: Bool) {
        if stopSync {
            RGCxrKit.shared.send(cmd: .Med, subCmd: .Sync_Stop)
        }
        installTimeoutWorkItem?.cancel()
        installTimeoutWorkItem = nil
        
        let requestId = pendingRequestId
        let tempApkPath = pendingApkPath
        pendingRequestId = nil
        pendingApkPath = nil
        pendingFileName = nil
        expectedServerIP = nil
        resolvedServerIP = nil
        isInstalling = false
        
        if let tempApkPath {
            cleanupTempFile(at: tempApkPath)
        }
        
        if let requestId {
            delegate?.apkInstallServiceDidFinish(requestId: requestId, success: success)
        }
    }
    
    private func cleanupAllTempFiles() {
        let folderURL = tempFolderURL()
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
            RGLog.info("[CxrServer][ApkInstall] 启动清理临时APK目录: \(folderURL.path), count: \(files.count)")
        } catch {
            RGLog.error("[CxrServer][ApkInstall] 启动清理临时APK目录失败: \(error.localizedDescription)")
        }
    }
    
    private func cleanupTempFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            RGLog.info("[CxrServer][ApkInstall] 清理临时APK: \(url.lastPathComponent)")
        } catch {
            RGLog.error("[CxrServer][ApkInstall] 清理临时APK失败: \(error.localizedDescription)")
        }
    }
    
    private func tempFolderURL() -> URL {
        let documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentDir.appendingPathComponent(tempFolderName, isDirectory: true)
    }
    
    private func isPrivateIP(_ ip: String) -> Bool {
        ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")
    }
    
    private func getDefaultGateway() -> String? {
        var name: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_DUMP2, 0]
        let nameSize = u_int(name.count)
        var bufferSize = 0
        sysctl(&name, nameSize, nil, &bufferSize, nil, 0)
        guard bufferSize > 0 else { return nil }
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: bufferSize)
        guard sysctl(&name, nameSize, buffer, &bufferSize, nil, 0) == 0 else { return nil }
        
        var rt = buffer
        let end = rt.advanced(by: bufferSize)
        while rt < end {
            let msg = rt.withMemoryRebound(to: rt_msghdr2.self, capacity: 1) { $0.pointee }
            var addr = rt.advanced(by: MemoryLayout<rt_msghdr2>.stride)
            var dstAddr: in_addr?
            var gatewayAddr: in_addr?
            
            for i in 0..<RTAX_MAX {
                if (msg.rtm_addrs & (1 << i)) != 0 {
                    if i == RTAX_DST {
                        let si = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        dstAddr = si.sin_addr
                    } else if i == RTAX_GATEWAY {
                        let si = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        gatewayAddr = si.sin_addr
                    }
                }
                let sa = addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee }
                addr = addr.advanced(by: Int(sa.sa_len))
            }
            
            if let gateway = gatewayAddr,
               gateway.s_addr != INADDR_ANY,
               (dstAddr == nil || dstAddr!.s_addr == INADDR_ANY) {
                return String(cString: inet_ntoa(gateway), encoding: .ascii)
            }
            rt = rt.advanced(by: Int(msg.rtm_msglen))
        }
        return nil
    }
}

