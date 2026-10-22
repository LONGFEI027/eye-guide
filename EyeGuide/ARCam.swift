import Foundation
import ARKit
import SceneKit
import SwiftUI
import UIKit
import AVFoundation

/// ARKit 相机底座（护航开启时替代 CameraManager）：
/// 一个 ARSession 同时供——实时帧给模型（1fps JPEG）、原生取景渲染（ARPreviewView）、
/// 高清拍照（look_closely）、LiDAR 深度+位姿喂 Rover 障碍引擎（约6Hz）。
/// 所有重活（Rover、JPEG编码）都在后台串行队列，主线程只收回调——否则 UI 会卡死。
/// 注意：ARKit 独占相机，和 AVCaptureSession 二选一，由 Guide 负责切换。
final class ARCam: NSObject, ObservableObject, ARSessionDelegate {
    @Published var running = false                // 主线程

    var onSnapshot: ((Data) -> Void)?             // 1fps 喂实时模型（主线程回调）
    var wantsSnapshots = false
    var snapshotWidth: CGFloat = 640
    var onObstacle: ((Rover.Output) -> Void)?     // 约6Hz 障碍输出（主线程回调）

    let session = ARSession()                     // 给 ARPreviewView 共用

    static var supported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private let arQueue = DispatchQueue(label: "arcam.process", qos: .userInitiated)
    private let rover = Rover()
    private let ctx = CIContext()
    // 以下状态只在 arQueue 上碰
    private var lastSnap = Date.distantPast
    private var lastRover = Date.distantPast
    private var latestFrameImage: CIImage?

    func start() {
        guard Self.supported, !running else { return }
        let cfg = ARWorldTrackingConfiguration()
        cfg.frameSemantics = .sceneDepth
        cfg.planeDetection = []
        session.delegateQueue = arQueue           // 帧回调直接走后台队列
        session.delegate = self
        session.run(cfg, options: [.resetTracking])
        arQueue.async { self.rover.reset() }
        running = true
    }

    func stop() {
        guard running else { return }
        session.pause()
        running = false
    }

    // 在 arQueue 上执行
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date()
        // 障碍引擎 ~6Hz
        if now.timeIntervalSince(lastRover) > 0.16 {
            lastRover = now
            if let out = rover.ingest(frame) {
                DispatchQueue.main.async { self.onObstacle?(out) }
            }
        }
        // 实时帧 1fps（竖屏转正；编码在后台，主线程只收数据）
        if wantsSnapshots, now.timeIntervalSince(lastSnap) > 1.0 {
            lastSnap = now
            let img = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            latestFrameImage = img
            if let jpeg = jpeg(img, maxWidth: snapshotWidth) {
                DispatchQueue.main.async { self.onSnapshot?(jpeg) }
            }
        } else if now.timeIntervalSince(lastSnap) > 2.0 {
            // 没开实时帧时也低频留一帧，给高清拍照降级用
            lastSnap = now
            latestFrameImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        }
    }

    /// look_closely 的高清拍照：iOS16+ 用 ARKit 高分辨率帧（约12MP），否则用最近一帧
    func captureHiRes(_ completion: @escaping (Data?) -> Void) {
        guard running else { DispatchQueue.main.async { completion(nil) }; return }
        if #available(iOS 16.0, *) {
            session.captureHighResolutionFrame { [weak self] frame, _ in
                guard let self else { DispatchQueue.main.async { completion(nil) }; return }
                self.arQueue.async {
                    var data: Data?
                    if let frame {
                        let img = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
                        data = self.jpeg(img, maxWidth: 2048, quality: 0.8)
                    } else if let img = self.latestFrameImage {
                        data = self.jpeg(img, maxWidth: 1920, quality: 0.8)
                    }
                    DispatchQueue.main.async { completion(data) }
                }
            }
        } else {
            arQueue.async {
                let data = self.latestFrameImage.flatMap { self.jpeg($0, maxWidth: 1920, quality: 0.8) }
                DispatchQueue.main.async { completion(data) }
            }
        }
    }

    /// 手电筒：ARKit 占用相机期间仍可锁设备开关闪光灯
    func setTorch(_ on: Bool) {
        guard let dev = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video), dev.hasTorch else { return }
        try? dev.lockForConfiguration()
        dev.torchMode = on ? .on : .off
        dev.unlockForConfiguration()
    }

    private func jpeg(_ image: CIImage, maxWidth: CGFloat, quality: CGFloat = 0.7) -> Data? {
        let s = min(1, maxWidth / max(image.extent.width, 1))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}

/// ARKit 原生取景视图：共用 ARCam 的 session，60fps 渲染、CPU 零额外开销
struct ARPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = false
        v.antialiasingMode = .none
        v.preferredFramesPerSecond = 30
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
