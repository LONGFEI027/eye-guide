//
//  RGCxr3rdAppService.swift
//  RGCxrServer
//
//  Created by Ginger on 2026/3/16.
//

import UIKit
import RGCxrKit
import Combine
import RGCoreKit

internal protocol RGCxr3rdAppServiceDelegate: AnyObject {
    func thirdAppServiceDidQueryApp(requestId: Int, packageName: String, installed: Bool)
    func thirdAppServiceDidOpenApp(requestId: Int, packageName: String, success: Bool)
    func thirdAppServiceDidStopApp(requestId: Int, packageName: String, success: Bool)
    func thirdAppServiceDidUninstallApp(requestId: Int, packageName: String, success: Bool)
}

internal final class RGCxr3rdAppService: NSObject {
    
    private enum PendingOperation {
        case query
        case open
        case stop
        case uninstall
    }
    
    internal static let shared = RGCxr3rdAppService()
    internal weak var delegate: RGCxr3rdAppServiceDelegate?
    
    private var cancellables = Set<AnyCancellable>()
    private var pendingQueryRequestIds: [String: Int] = [:]
    private var pendingOpenRequestIds: [String: Int] = [:]
    private var pendingStopRequestIds: [String: Int] = [:]
    private var pendingUninstallRequestIds: [String: Int] = [:]
    private var pendingTimeoutWorkItems: [Int: DispatchWorkItem] = [:]
    private let timeoutInterval: TimeInterval = 2.0
    private let lock = NSLock()
    
    private override init() {
        super.init()
        RGCxrKit.shared.dataNotifyPublisher.sink { response in
            if response.enumSubCmd == .Sys_App_Query {
                guard let resultStr = response.responseData as? String,
                      let data = resultStr.data(using: .utf8),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return
                }
                for (packageName, installedStr) in result {
                    let installed = installedStr.lowercased() == "true"
                    let requestId = self.resolveRequestId(&self.pendingQueryRequestIds, packageName: packageName)
                    self.cancelTimeout(requestId: requestId)
                    self.delegate?.thirdAppServiceDidQueryApp(requestId: requestId, packageName: packageName, installed: installed)
                }
            } else if response.enumSubCmd == .Sys_App_Open_Succeed {
                let packageName = self.extractPackageName(from: response.responseData)
                let requestId = self.resolveRequestId(&self.pendingOpenRequestIds, packageName: packageName)
                self.cancelTimeout(requestId: requestId)
                self.delegate?.thirdAppServiceDidOpenApp(requestId: requestId, packageName: packageName, success: true)
            } else if response.enumSubCmd == .Sys_App_Open_Failed {
                let packageName = self.extractPackageName(from: response.responseData)
                let requestId = self.resolveRequestId(&self.pendingOpenRequestIds, packageName: packageName)
                self.cancelTimeout(requestId: requestId)
                self.delegate?.thirdAppServiceDidOpenApp(requestId: requestId, packageName: packageName, success: false)
            } else if response.enumSubCmd == .Sys_App_Stop_Succeed {
                let packageName = self.extractPackageName(from: response.responseData)
                let requestId = self.resolveRequestId(&self.pendingStopRequestIds, packageName: packageName)
                self.cancelTimeout(requestId: requestId)
                self.delegate?.thirdAppServiceDidStopApp(requestId: requestId, packageName: packageName, success: true)
            } else if response.enumSubCmd == .Sys_App_Stop_Failed {
                let packageName = self.extractPackageName(from: response.responseData)
                let requestId = self.resolveRequestId(&self.pendingStopRequestIds, packageName: packageName)
                self.cancelTimeout(requestId: requestId)
                self.delegate?.thirdAppServiceDidStopApp(requestId: requestId, packageName: packageName, success: false)
            } else if response.enumSubCmd == .Sys_Apk_Uninstall_Succeed {
                let packageName = self.extractPackageName(from: response.responseData)
                let requestId = self.resolveRequestId(&self.pendingUninstallRequestIds, packageName: packageName)
                self.cancelTimeout(requestId: requestId)
                self.delegate?.thirdAppServiceDidUninstallApp(requestId: requestId, packageName: packageName, success: true)
            } else if response.enumSubCmd == .Sys_Apk_Uninstall_Failed {
                let packageName = self.extractPackageName(from: response.responseData)
                let requestId = self.resolveRequestId(&self.pendingUninstallRequestIds, packageName: packageName)
                self.cancelTimeout(requestId: requestId)
                self.delegate?.thirdAppServiceDidUninstallApp(requestId: requestId, packageName: packageName, success: false)
            }
            
        }.store(in: &cancellables)
    }
    
    func queryApp(requestId: Int, packageName: String) {
        lock.lock()
        pendingQueryRequestIds[packageName] = requestId
        lock.unlock()
        scheduleTimeout(requestId: requestId, packageName: packageName, operation: .query)
        RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_App_Query, data: packageName)
    }

    
    func openApp(requestId: Int, packageName: String, activityName: String, url: String) {
        lock.lock()
        pendingOpenRequestIds[packageName] = requestId
        lock.unlock()
        scheduleTimeout(requestId: requestId, packageName: packageName, operation: .open)
        RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_App_Open, data: [
            "packageName": packageName,
            "activityName": activityName,
            "url": url
        ].toJsonString())
    }
    
    func stopApp(requestId: Int, _ packageName: String) {
        lock.lock()
        pendingStopRequestIds[packageName] = requestId
        lock.unlock()
        scheduleTimeout(requestId: requestId, packageName: packageName, operation: .stop)
        RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_App_Stop, data: packageName)
    }
    
    func uninstallApp(requestId: Int, _ packageName: String) {
        lock.lock()
        pendingUninstallRequestIds[packageName] = requestId
        lock.unlock()
        scheduleTimeout(requestId: requestId, packageName: packageName, operation: .uninstall)
        RGCxrKit.shared.send(cmd: .Sys, subCmd: .Sys_Apk_Uninstall, data: packageName)
    }
    
    private func extractPackageName(from responseData: Any?) -> String {
        if let str = responseData as? String {
            if let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                return (json["packageName"] as? String) ?? ""
            } else {
                return str
            }
        }
        return ""
    }
    
    private func resolveRequestId(_ map: inout [String: Int], packageName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let requestId = map.removeValue(forKey: packageName) {
            return requestId
        }
        if let first = map.first {
            map.removeValue(forKey: first.key)
            return first.value
        }
        return 0
    }
    
    private func scheduleTimeout(requestId: Int, packageName: String, operation: PendingOperation) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.handleTimeout(requestId: requestId, packageName: packageName, operation: operation)
        }
        
        lock.lock()
        pendingTimeoutWorkItems[requestId]?.cancel()
        pendingTimeoutWorkItems[requestId] = workItem
        lock.unlock()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }
    
    private func cancelTimeout(requestId: Int) {
        guard requestId > 0 else { return }
        lock.lock()
        pendingTimeoutWorkItems[requestId]?.cancel()
        pendingTimeoutWorkItems.removeValue(forKey: requestId)
        lock.unlock()
    }
    
    private func handleTimeout(requestId: Int, packageName: String, operation: PendingOperation) {
        lock.lock()
        pendingTimeoutWorkItems.removeValue(forKey: requestId)
        
        let shouldTrigger: Bool
        switch operation {
        case .query:
            shouldTrigger = pendingQueryRequestIds[packageName] == requestId
            if shouldTrigger { pendingQueryRequestIds.removeValue(forKey: packageName) }
        case .open:
            shouldTrigger = pendingOpenRequestIds[packageName] == requestId
            if shouldTrigger { pendingOpenRequestIds.removeValue(forKey: packageName) }
        case .stop:
            shouldTrigger = pendingStopRequestIds[packageName] == requestId
            if shouldTrigger { pendingStopRequestIds.removeValue(forKey: packageName) }
        case .uninstall:
            shouldTrigger = pendingUninstallRequestIds[packageName] == requestId
            if shouldTrigger { pendingUninstallRequestIds.removeValue(forKey: packageName) }
        }
        lock.unlock()
        
        guard shouldTrigger else { return }
        
        RGLog.warn("[RGCxr3rdAppService] 第三方应用操作超时，requestId: \(requestId), packageName: \(packageName), operation: \(operation)")
        switch operation {
        case .query:
            delegate?.thirdAppServiceDidQueryApp(requestId: requestId, packageName: packageName, installed: false)
        case .open:
            delegate?.thirdAppServiceDidOpenApp(requestId: requestId, packageName: packageName, success: false)
        case .stop:
            delegate?.thirdAppServiceDidStopApp(requestId: requestId, packageName: packageName, success: false)
        case .uninstall:
            delegate?.thirdAppServiceDidUninstallApp(requestId: requestId, packageName: packageName, success: false)
        }
    }
}
