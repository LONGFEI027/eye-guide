//
//  RGNetwork.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/7/30.
//

import Foundation
import Combine

public enum RGNetworkConnection: String {
    case wifi = "WiFi"
    case cellular = "5G"
    case unavailable
}

public protocol RGNetworkDelegate: NSObjectProtocol {
    func onNetworkChanged(_ isReachable: Bool)
}

public class RGNetwork: NSObject {
    
    fileprivate let reachability = try! Reachability()
    
    public static let shared = RGNetwork()
    
    private var isReachableSubject: CurrentValueSubject<Bool, Never>
    private var connectionSubject: CurrentValueSubject<RGNetworkConnection, Never>
    
    /// 当前是否可达（与 `isReachable` 同步，订阅时会立即收到当前值）
    public var isReachablePublisher: AnyPublisher<Bool, Never> {
        isReachableSubject.eraseToAnyPublisher()
    }
    
    /// 当前连接类型（与 `connection` 同步，订阅时会立即收到当前值）
    public var connectionPublisher: AnyPublisher<RGNetworkConnection, Never> {
        connectionSubject.eraseToAnyPublisher()
    }
    
    var delegates = NSPointerArray.weakObjects()
    
    public var isReachable: Bool  {
        reachability.connection != .unavailable
    }
    
    public var connection: RGNetworkConnection {
        switch reachability.connection {
        case .unavailable:
            return .unavailable
        case .wifi:
            return .wifi
        case .cellular:
            return .cellular
        }
    }
    
    public override init() {
        let initialReachable = reachability.connection != .unavailable
        let initialConnection: RGNetworkConnection
        switch reachability.connection {
        case .unavailable:
            initialConnection = .unavailable
        case .wifi:
            initialConnection = .wifi
        case .cellular:
            initialConnection = .cellular
        }
        isReachableSubject = CurrentValueSubject(initialReachable)
        connectionSubject = CurrentValueSubject(initialConnection)
        super.init()
        networkMonitor()
    }
    
    /// 网络监听
    func networkMonitor() {
        reachability.whenReachable = { [weak self] reach in
            RGLog.info("Network is reachable: \(reach.connection)")
            guard let self else { return }
            self.isReachableSubject.send(true)
            self.connectionSubject.send(self.connection)
            self.delegates.forEachWeakObject { (obj: NSObjectProtocol?) in
                if let listener = obj as? RGNetworkDelegate {
                    listener.onNetworkChanged(true)
                }
            }
        }
        reachability.whenUnreachable = { [weak self] reach in
            RGLog.info("Network is unreachable: \(reach.connection)")
            guard let self else { return }
            self.isReachableSubject.send(false)
            self.connectionSubject.send(self.connection)
            self.delegates.forEachWeakObject { (obj: NSObjectProtocol?) in
                if let listener = obj as? RGNetworkDelegate {
                    listener.onNetworkChanged(false)
                }
            }
        }
        do {
            try reachability.startNotifier()
        } catch {
            RGLog.error("could not start reachability notifier.")
        }
    }
    
    public func addDelegate(_ delegate: RGNetworkDelegate) {
        delegates.addWeakObject(delegate)
    }
    
    public func removeDelegate(_ delegate: RGNetworkDelegate) {
        delegates.removeWeakObject(delegate)
    }
    
    /// 获取设备的局域网IP地址（优先返回Wi-Fi的IPv4地址）
    public func getLocalIPAddress() -> String? {
        // 方法1：通过getifaddrs获取网络接口信息（兼容所有iOS版本）
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family ?? 0
                
                // 只处理IPv4地址
                guard addrFamily == UInt8(AF_INET) else { continue }
                
                // 过滤回环地址和非活跃接口
                let name = String(cString: (interface?.ifa_name)!)
                guard !name.contains("lo") && (interface?.ifa_flags ?? 0) & UInt32(IFF_UP) != 0 else { continue }
                
                // 转换为IPv4地址结构体
                let addr = interface?.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                
                // 转换为字符串
                var hostName = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!), &hostName, socklen_t(hostName.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    address = String(cString: hostName)
                    
                    // 优先返回Wi-Fi接口的IP（en0通常是Wi-Fi）
                    if name == "en0" {
                        break
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        
        return address
    }
}
