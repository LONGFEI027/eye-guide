//
//  RGCxrClientLifecycle.swift
//  RGCxrClient
//

import Combine
import Foundation

internal enum RGCxrClientLifecycle {
    private static let lock = NSLock()
    private static var _initialized = false
    private static var _snapshot: (mode: RGCxrClientInitMode?, options: RGCxrClientInitializationOptions)?

    /// 与鉴权、业务事件发布器组合，用于在未完成 `CxrClient.initialize` 前不向外部透出任何事件。
    static let initializedSubject = CurrentValueSubject<Bool, Never>(false)

    static var isInitialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _initialized
    }

    static var snapshot: (mode: RGCxrClientInitMode?, options: RGCxrClientInitializationOptions)? {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    /// - Returns: 若本次调用完成首次初始化则为 `true`；若进程内已初始化过则为 `false`。
    @discardableResult
    static func performFirstInitialize(
        mode: RGCxrClientInitMode,
        options: RGCxrClientInitializationOptions,
        completion: () -> Void
    ) -> Bool {
        performFirstInitialize(mode: Optional(mode), options: options, completion: completion)
    }

    /// `RGCxrLink` 入口初始化：允许先完成鉴权与 BLE 自动建链，稍后创建 typed session 时再固定业务模式。
    @discardableResult
    static func performFirstInitialize(
        options: RGCxrClientInitializationOptions,
        completion: () -> Void
    ) -> Bool {
        performFirstInitialize(mode: nil, options: options, completion: completion)
    }

    /// 绑定业务模式。若已经由旧接口或其它 session 固定为不同模式，则返回 `false`。
    @discardableResult
    static func bindModeIfNeeded(
        mode: RGCxrClientInitMode,
        options: RGCxrClientInitializationOptions,
        completion: () -> Void
    ) -> Bool {
        lock.lock()
        if !_initialized {
            _initialized = true
            _snapshot = (mode, options)
            lock.unlock()
            completion()
            initializedSubject.send(true)
            return true
        }
        if let currentMode = _snapshot?.mode {
            let currentOptions = _snapshot?.options
            lock.unlock()
            guard currentMode == mode, currentOptions?.pageName == options.pageName else {
                return false
            }
            return true
        }
        _snapshot = (mode, options)
        lock.unlock()
        completion()
        initializedSubject.send(true)
        return true
    }

    private static func performFirstInitialize(
        mode: RGCxrClientInitMode?,
        options: RGCxrClientInitializationOptions,
        completion: () -> Void
    ) -> Bool {
        lock.lock()
        if _initialized {
            lock.unlock()
            return false
        }
        _initialized = true
        _snapshot = (mode, options)
        lock.unlock()
        completion()
        initializedSubject.send(true)
        return true
    }
}
