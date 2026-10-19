//
//  RGTimer.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/7/9.
//

import Foundation
public class RGTimer {
    private var timer: DispatchSourceTimer?
    public private(set) var isRunning = false
    private var remainingTime: TimeInterval = 0
    private var isCountdownMode = false
    public init() {}
    /// 创建并启动定时器
    /// - Parameters:
    ///   - interval: 时间间隔（秒）
    ///   - queue: 执行队列，默认为主队列
    ///   - handler: 定时器触发时的回调
    ///   - repeats: 是否重复
    ///   - immediate: 是否立刻执行
    
    public func start(interval: TimeInterval,
                      queue: DispatchQueue = .main,
                      repeats: Bool = true,
                      immediate: Bool = true,
                      handler: @escaping () -> Void) {
        // 如果已有定时器运行，先取消
        stop()
        
        // 创建定时器
        timer = DispatchSource.makeTimerSource(queue: queue)
        
        // 设置定时器参数
        let deadline: DispatchTime = immediate ? .now() : .now() + interval
        let repeating: DispatchTimeInterval = repeats ? .nanoseconds(Int(interval * 1_000_000_000)) : .never
        // 设置定时器
        timer?.schedule(deadline: deadline, repeating: repeating)
        
        // 设置定时器回调
        timer?.setEventHandler { [weak self] in
            guard self?.isRunning == true else { return }
            handler()
            
            // 如果不是重复执行，执行一次后停止
            if !repeats {
                self?.stop()
            }
        }
        // 启动定时器
        timer?.resume()
        isRunning = true
        isCountdownMode = false
    }
    
    /// 启动倒计时
    /// - Parameters:
    ///   - duration: 倒计时总时长（秒）
    ///   - interval: 更新间隔（秒），默认为 1 秒
    ///   - queue: 执行队列，默认为主队列
    ///   - onTick: 每次更新时的回调，返回剩余时间（秒），默认为 nil
    ///   - onComplete: 倒计时完成时的回调
    public func startCountdown(duration: TimeInterval,
                               interval: TimeInterval = 1.0,
                               queue: DispatchQueue = .main,
                               onTick: ((TimeInterval) -> Void)? = nil,
                               onComplete: @escaping () -> Void) {
        // 如果已有定时器运行，先取消
        stop()
        
        // 初始化倒计时参数
        remainingTime = duration
        isCountdownMode = true
        
        // 立即回调初始时间
        onTick?(remainingTime)
        
        // 创建定时器
        timer = DispatchSource.makeTimerSource(queue: queue)
        
        // 设置定时器参数（从下一个间隔开始）
        timer?.schedule(deadline: .now() + interval, repeating: .nanoseconds(Int(interval * 1_000_000_000)))
        
        // 设置定时器回调
        timer?.setEventHandler { [weak self] in
            guard let self = self, self.isRunning, self.isCountdownMode else { return }
            
            // 减少剩余时间
            self.remainingTime -= interval
            
            // 如果倒计时结束
            if self.remainingTime <= 0 {
                self.remainingTime = 0
                onTick?(0)
                self.stop()
                onComplete()
            } else {
                onTick?(self.remainingTime)
            }
        }
        
        // 启动定时器
        timer?.resume()
        isRunning = true
    }
    
    /// 停止定时器
    public func stop() {
        guard isRunning else { return }
        
        timer?.cancel()
        timer = nil
        isRunning = false
        isCountdownMode = false
        remainingTime = 0
    }
    
    deinit {
        stop()
    }
}
