import Foundation
import ARKit
import UIKit
import AVFoundation

/// ARKit 相机底座（护航开启时替代 CameraManager）：
/// 一个 ARSession 同时供——实时帧给模型（1fps JPEG）、界面预览（1fps）、
/// 高清拍照（look_closely）、LiDAR 深度+位姿喂 Rover 障碍引擎（约6Hz）。
/// 注意：ARKit 独占相机，和 AVCaptureSession 二选一，由 Guide 负责切换。
@MainActor
final class ARCam: NSObject, ObservableObject, ARSessionDelegate {
    @Published var running = false
    @Published var preview: UIImage?              // 约1fps，给明眼人/调试看

    var onSnapshot: ((Data) -> Void)?             // 1fps 喂实时模型
    var wantsSnapshots = false
    var snapshotWidth: CGFloat = 640
    var onObstacle: ((Rover.Output) -> Void)?     // 约6Hz 障碍输出

    static var supported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private let session = ARSession()
    private let rover = Rover()
    private let ctx = CIContext()
    private var lastSnap = Date.distantPast
    private var lastPreview = Date.distantPast
    private var lastRover = Date.distantPast
    private var latestFrameImage: CIImage?        // 高清拍照降级用

    func start() {
        guard Self.supported, !running else { return }
        let cfg = ARWorldTrackingConfiguration()
        cfg.frameSemantics = .sceneDepth
        cfg.planeDetection = []
        session.delegate = self
        session.run(cfg, options: [.resetTracking])
        rover.reset()
        running = true
    }

    func stop() {
        guard running else { return }
        session.pause()
        running = false
        preview = nil
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARSession 默认回调在主线程
        MainActor.assumeIsolated {
            let now = Date()
            // 障碍引擎 ~6Hz
            if now.timeIntervalSince(lastRover) > 0.16 {
                lastRover = now
                if let out = rover.ingest(frame) { onObstacle?(out) }
            }
            // 实时帧 1fps（竖屏转正）
            if wantsSnapshots, now.timeIntervalSince(lastSnap) > 1.0 {
                lastSnap = now
                let img = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
                latestFrameImage = img
                if let jpeg = jpeg(img, maxWidth: snapshotWidth) { onSnapshot?(jpeg) }
            }
            // 预览 1fps
            if now.timeIntervalSince(lastPreview) > 1.0 {
                lastPreview = now
                let img = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
                latestFrameImage = img
                if let small = jpeg(img, maxWidth: 480), let ui = UIImage(data: small) {
                    preview = ui
                }
            }
        }
    }

    /// look_closely 的高清拍照：iOS16+ 用 ARKit 高分辨率帧（约12MP），否则用当前帧（1920×1440）
    func captureHiRes(_ completion: @escaping (Data?) -> Void) {
        guard running else { completion(nil); return }
        if #available(iOS 16.0, *) {
            session.captureHighResolutionFrame { [weak self] frame, _ in
                Task { @MainActor in
                    guard let self else { completion(nil); return }
                    if let frame {
                        let img = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
                        completion(self.jpeg(img, maxWidth: 2048, quality: 0.8))
                    } else if let img = self.latestFrameImage {
                        completion(self.jpeg(img, maxWidth: 1920, quality: 0.8))
                    } else {
                        completion(nil)
                    }
                }
            }
        } else if let img = latestFrameImage {
            completion(jpeg(img, maxWidth: 1920, quality: 0.8))
        } else {
            completion(nil)
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
