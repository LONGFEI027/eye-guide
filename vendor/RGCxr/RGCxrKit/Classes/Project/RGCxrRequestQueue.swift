//
//  RGCxrRequestQueue.swift
//  Pods
//
//  Created by Ginger on 2025/4/2.
//
import RGCoreKit

class RGCxrRequestQueue {
    
    var models: [RGCxrRequestModel] = []
    
    // 设置为5秒超时
    let timeout: Double = 5
    
    // 用于线程安全的队列
    private let syncQueue = DispatchQueue(label: "com.rokid.RGCxrRequestQueue.syncQueue")

    // 定时器
    private var timer: Timer?
    
    func addModel(_ model: RGCxrRequestModel) {
        RGLog.api(model.reqId)
        Task {
            syncQueue.sync {
                models.append(model)
            }
        }
        startCheckingIfNeeded()
    }
    
    func removeModel(_ model: RGCxrRequestModel) {
        RGLog.api(model.reqId)
        Task {
            syncQueue.sync {
                models.removeAll(where: { $0.reqId == model.reqId })
            }
        }
        stopCheckingIfNeeded()
    }
    
    func getModel(by requestId: Int32, callback: ((RGCxrRequestModel?) -> Void)?) {
        RGLog.api(requestId)
        Task {
            syncQueue.sync {
                let result = models.first(where: { $0.reqId == requestId })
                DispatchQueue.main.async {
                    callback?(result)
                }
            }
        }
    }
    
    private func startCheckingIfNeeded() {
        Task {
            syncQueue.sync {
                if timer == nil,
                   !models.isEmpty {
                    timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(checkForTimeout), userInfo: nil, repeats: true)
                    RunLoop.current.add(timer!, forMode: .common)
                }
            }
        }
    }
    
    private func stopCheckingIfNeeded() {
        Task {
            syncQueue.sync {
                guard models.isEmpty else { return }
                timer?.invalidate()
                timer = nil
            }
        }
    }
    
    @objc private func checkForTimeout() {
        Task {
            syncQueue.sync {
                let timeoutModels = models.filter { Date().timeIntervalSince1970 - $0.requestTime > timeout }
                for model in timeoutModels {
                    // 回调超时
                    RGLog.info("Request \(model.reqId) has timed out.")
                    removeModel(model)
                }
            }
        }
    }
}
