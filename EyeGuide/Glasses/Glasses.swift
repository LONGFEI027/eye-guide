import Foundation
import Combine
import UIKit
import RGCxrClient

/// Rokid 眼镜（CXR-L SDK，经 Hi Rokid / Rokid AI App 鉴权，蓝牙直连）。
/// 实测节奏（2026-10-20，RV101 + iPhone 14 Pro）：单张 2.7~4 秒；
/// 连拍必须张间歇 ≥0.8 秒，否则 SDK 静默丢请求（无回调）；必须带超时看门狗；
/// 眼镜不戴会睡眠断链，openCustomView 会失败——提示用户戴上。
@MainActor
final class Glasses: ObservableObject {
    enum State: Equatable {
        case off            // 眼镜模式关着
        case needAuth       // 等用户在 Rokid App 里点授权
        case connecting     // 正在开眼镜端会话
        case ready          // 可以拍照了
        case error(String)
    }
    @Published var state: State = .off
    @Published var wearing = true            // 佩戴状态（不戴会断链）
    @Published var battery: Int?
    @Published var lastPhoto: UIImage?       // 最近一张（界面预览）
    /// 用户开关：开了之后小路的眼睛切到眼镜
    @Published var enabled = UserDefaults.standard.bool(forKey: "glasses.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "glasses.enabled") }
    }

    private let client = CxrClient.shared
    private var bag = Set<AnyCancellable>()
    private var busy = false                 // 同一时刻只允许一张在途
    private var lastShot = Date.distantPast

    /// SDK 全局初始化只许一次（customView 模式：手机下发界面，不装眼镜端 App）
    private static let bootstrap: Void = {
        _ = CxrClient.initialize(mode: .customView, options: .init(appDisplayName: "小路", pageName: nil))
    }()

    init() {
        _ = Self.bootstrap
        // 鉴权回调用自己的 scheme，避免和官方 Demo 的 cxrl 撞车（Info.plist 已注册 xiaolu）
        var cfg = client.auth.config
        cfg.callbackScheme = "xiaolu"
        client.auth.config = cfg

        client.customViewRunningEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] e in
                guard let self else { return }
                if !e.isRunning, self.state == .ready { self.state = .connecting }   // 会话掉了（多半是眼镜睡了）
                else if e.isRunning, self.state == .connecting { self.state = .ready }
            }.store(in: &bag)
        client.wearingStatusEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.wearing = on }.store(in: &bag)
        client.deviceInfoEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in self?.battery = info.batteryLevel }.store(in: &bag)
    }

    /// 鉴权跳转回来的 URL 交给 SDK
    func handleOpenURL(_ url: URL) -> Bool { client.handleOpenURL(url) }

    /// 开眼镜模式：未鉴权先跳 Rokid App 授权，然后开眼镜端会话
    func start() {
        guard client.isRokidAppInstalled() else {
            state = .error("手机上没装 Rokid 配套App（Hi Rokid），装好配对眼镜后再试")
            return
        }
        if client.auth.isAuthenticated() {
            openSession()
        } else {
            state = .needAuth
            client.auth.authenticate(scopes: [.microphone, .camera], appName: "小路") { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success: self?.openSession()
                    case .failure(let e): self?.state = .error("眼镜授权没成功：\(e.localizedDescription)")
                    }
                }
            }
        }
    }

    func stop() {
        _ = client.closeCustomView(callback: nil)
        state = .off
    }

    /// 眼镜端显示的极简界面（绿色单色光波导，文字用绿色）；开着它 = 会话活着 = 才能拍照
    private static let viewJSON = """
    {"type":"LinearLayout","props":{"layout_width":"match_parent","layout_height":"match_parent",\
    "orientation":"vertical","gravity":"center"},"children":[{"type":"TextView","props":{"id":"tv_status",\
    "layout_width":"wrap_content","layout_height":"wrap_content","text":"小路正在帮你看",\
    "textColor":"#FF00FF00","textSize":"20sp","textStyle":"bold"}}]}
    """

    private func openSession(retry: Int = 0) {
        state = .connecting
        let err = client.openCustomView(Self.viewJSON) { [weak self] ok, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.state = .ready
                    _ = self.client.getDeviceInfo { [weak self] info in
                        DispatchQueue.main.async { self?.battery = info?.batteryLevel }
                    }
                } else if retry < 1 {
                    self.openSession(retry: retry + 1)       // 眼镜刚唤醒时第一次常失败，重试一次
                } else {
                    self.state = .error("连不上眼镜：请戴上眼镜，确认 Rokid App 里显示已连接")
                }
            }
        }
        if err != nil {
            state = .error("眼镜未就绪，请先在 Rokid App 里连好眼镜再开")
        }
    }

    /// 拍一张（节流 + 看门狗）。失败回 nil，调用方自行降级。
    func takePhoto(width: Int, height: Int, quality: Int,
                   timeout: TimeInterval = 12, completion: @escaping (Data?) -> Void) {
        guard state == .ready, !busy else { completion(nil); return }
        busy = true
        let wait = max(0, 0.8 - Date().timeIntervalSince(lastShot))   // 张间歇 ≥0.8s
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            var settled = false
            let done: (Data?) -> Void = { [weak self] data in
                guard let self, !settled else { return }
                settled = true
                self.busy = false
                self.lastShot = Date()
                if let data, let img = UIImage(data: data) { self.lastPhoto = img }
                completion(data)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { done(nil) }   // 看门狗
            let err = self.client.takePhotoWithData(width: width, height: height, quality: quality) { data in
                DispatchQueue.main.async { done(data) }
            }
            if err != nil { done(nil) }
        }
    }
}
