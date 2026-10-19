//
//  RGCxrCustomViewService.swift
//  RGCxrServer
//
//  Created by Ginger on 2026/4/24.
//

import Foundation
import Combine
import RGCoreKit
import RGCxrKit

internal protocol RGCxrCustomViewServiceDelegate: AnyObject {
    func customViewServiceDidSendIcons(requestId: Int, success: Bool)
    func customViewServiceDidOpen(requestId: Int, success: Bool, errorCode: Int?)
    func customViewServiceDidUpdate(requestId: Int, success: Bool)
    func customViewServiceDidClose(requestId: Int, success: Bool)
}

/// 自定义 View 相关命令（Send_Custom_View_Icons / Open / Update / Close）的请求-响应服务。
///
/// 眼镜侧对上述命令的回包是一条独立的 notify（`Custom_View_Icons_Sent` / `Custom_View_Opened` /
/// `Custom_View_Open_Failed` / `Custom_View_Updated` / `Custom_View_Closed`），因此这里通过监听
/// `dataNotifyPublisher` 匹配回包。若在 `timeoutInterval` 内未收到，则按失败处理。
internal final class RGCxrCustomViewService {
    
    internal enum Operation {
        case sendIcons
        case open
        case update
        case close
    }
    
    internal static let shared = RGCxrCustomViewService()
    internal weak var delegate: RGCxrCustomViewServiceDelegate?
    
    private let lock = NSLock()
    /// 每种类型的请求 FIFO 队列（同类型通常不会并发，这里用 FIFO 提升稳健性）。
    private var pendingSendIcons: [Int] = []
    private var pendingOpen: [Int] = []
    private var pendingUpdate: [Int] = []
    private var pendingClose: [Int] = []
    private var pendingTimeoutWorkItems: [Int: DispatchWorkItem] = [:]
    private let timeoutInterval: TimeInterval = 5.0
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        RGCxrKit.shared.dataNotifyPublisher
            .sink { [weak self] response in
                self?.handleNotify(response)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 发送请求
    
    internal func sendIcons(requestId: Int, icons: String) {
        enqueue(operation: .sendIcons, requestId: requestId)
        RGCxrKit.shared.send(cmd: .Custom_View, subCmd: .Send_Custom_View_Icons, data: icons)
    }
    
    internal func openCustomView(requestId: Int, view: String) {
        enqueue(operation: .open, requestId: requestId)
        RGCxrKit.shared.send(cmd: .Custom_View, subCmd: .Open_Custom_View, data: view)
    }
    
    internal func updateCustomView(requestId: Int, view: String) {
        enqueue(operation: .update, requestId: requestId)
        RGCxrKit.shared.send(cmd: .Custom_View, subCmd: .Update_Custom_View, data: view)
    }
    
    internal func closeCustomView(requestId: Int) {
        enqueue(operation: .close, requestId: requestId)
        RGCxrKit.shared.send(cmd: .Custom_View, subCmd: .Close_Custom_View)
    }
    
    // MARK: - Notify 处理
    
    private func handleNotify(_ response: RGCxrDataResponse) {
        guard response.enumCmd == .Custom_View else { return }
        switch response.enumSubCmd {
        case .Custom_View_Icons_Sent:
            if let requestId = dequeue(operation: .sendIcons) {
                cancelTimeout(requestId: requestId)
                delegate?.customViewServiceDidSendIcons(requestId: requestId, success: true)
            }
        case .Custom_View_Opened:
            if let requestId = dequeue(operation: .open) {
                cancelTimeout(requestId: requestId)
                delegate?.customViewServiceDidOpen(requestId: requestId, success: true, errorCode: nil)
            }
        case .Custom_View_Open_Failed:
            if let requestId = dequeue(operation: .open) {
                cancelTimeout(requestId: requestId)
                let errorCode = extractErrorCode(from: response.responseData)
                delegate?.customViewServiceDidOpen(requestId: requestId, success: false, errorCode: errorCode)
            }
        case .Custom_View_Updated:
            if let requestId = dequeue(operation: .update) {
                cancelTimeout(requestId: requestId)
                delegate?.customViewServiceDidUpdate(requestId: requestId, success: true)
            }
        case .Custom_View_Closed:
            if let requestId = dequeue(operation: .close) {
                cancelTimeout(requestId: requestId)
                delegate?.customViewServiceDidClose(requestId: requestId, success: true)
            }
        default:
            break
        }
    }
    
    private func extractErrorCode(from responseData: Any?) -> Int? {
        if let info = responseData as? String,
           let data = info.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json["errorCode"] as? Int
        }
        if let json = responseData as? [String: Any] {
            return json["errorCode"] as? Int
        }
        return nil
    }
    
    // MARK: - 队列管理
    
    private func enqueue(operation: Operation, requestId: Int) {
        lock.lock()
        switch operation {
        case .sendIcons: pendingSendIcons.append(requestId)
        case .open: pendingOpen.append(requestId)
        case .update: pendingUpdate.append(requestId)
        case .close: pendingClose.append(requestId)
        }
        lock.unlock()
        scheduleTimeout(requestId: requestId, operation: operation)
    }
    
    private func dequeue(operation: Operation) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        switch operation {
        case .sendIcons: return pendingSendIcons.isEmpty ? nil : pendingSendIcons.removeFirst()
        case .open: return pendingOpen.isEmpty ? nil : pendingOpen.removeFirst()
        case .update: return pendingUpdate.isEmpty ? nil : pendingUpdate.removeFirst()
        case .close: return pendingClose.isEmpty ? nil : pendingClose.removeFirst()
        }
    }
    
    private func removePending(operation: Operation, requestId: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        func remove(_ queue: inout [Int]) -> Bool {
            if let idx = queue.firstIndex(of: requestId) {
                queue.remove(at: idx)
                return true
            }
            return false
        }
        switch operation {
        case .sendIcons: return remove(&pendingSendIcons)
        case .open: return remove(&pendingOpen)
        case .update: return remove(&pendingUpdate)
        case .close: return remove(&pendingClose)
        }
    }
    
    // MARK: - 超时处理
    
    private func scheduleTimeout(requestId: Int, operation: Operation) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.handleTimeout(requestId: requestId, operation: operation)
        }
        lock.lock()
        pendingTimeoutWorkItems[requestId]?.cancel()
        pendingTimeoutWorkItems[requestId] = workItem
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }
    
    private func cancelTimeout(requestId: Int) {
        lock.lock()
        let item = pendingTimeoutWorkItems.removeValue(forKey: requestId)
        lock.unlock()
        item?.cancel()
    }
    
    private func handleTimeout(requestId: Int, operation: Operation) {
        lock.lock()
        pendingTimeoutWorkItems.removeValue(forKey: requestId)
        lock.unlock()
        
        guard removePending(operation: operation, requestId: requestId) else {
            return
        }
        RGLog.warn("[CxrServer][CustomView] 操作超时，requestId: \(requestId), operation: \(operation)")
        switch operation {
        case .sendIcons:
            delegate?.customViewServiceDidSendIcons(requestId: requestId, success: false)
        case .open:
            delegate?.customViewServiceDidOpen(requestId: requestId, success: false, errorCode: nil)
        case .update:
            delegate?.customViewServiceDidUpdate(requestId: requestId, success: false)
        case .close:
            delegate?.customViewServiceDidClose(requestId: requestId, success: false)
        }
    }
}
