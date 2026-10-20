import AVFoundation
import UIKit

/// 相机：后置镜头取景、每秒一帧给模型看、高清拍照给视觉模型细看、变焦、手电筒。
/// 护航模式下换用激光雷达相机（builtInLiDARDepthCamera），同一条会话里多出一路深度流，
/// 持续报告正前方最近障碍的距离（本地、毫秒级，与大模型无关）。
/// 不做人脸/姿态分析（那是拍照 App 的事），省电优先——这个 App 要一直开着陪人走路。
final class CameraManager: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    @Published var isRunning = false
    @Published var permissionDenied = false
    @Published var zoomLabel = "1"
    @Published var torchOn = false

    /// 这台手机有没有激光雷达（14 Pro 有）
    static var lidarAvailable: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }
    /// 护航模式：true=用激光雷达相机并输出深度（变焦退化为数码变焦，超广角不可用）
    var wantsDepth = false
    /// 正前方最近障碍距离（米，已平滑，约 10Hz，主线程）
    var onObstacle: ((Float) -> Void)?

    /// 给模型看的实时帧（主线程，每秒 1 张，仅在 wantsSnapshots 时）
    var onSnapshot: ((Data) -> Void)?
    var wantsSnapshots = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let queue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.frames")
    private let ctx = CIContext()
    private var device: AVCaptureDevice?
    private var lastSnapshot = Date.distantPast
    private var lastDepth = Date.distantPast
    private var smoothedNear: Float = 0
    private var presets: [(label: String, factor: CGFloat)] = []
    private let pendingLock = NSLock()
    private var pending: [Int64: (Data?) -> Void] = [:]

    /// 开关护航模式（重配会话）
    func setDepth(_ on: Bool) {
        wantsDepth = on
        queue.async { self.configure() }
    }

    func start() {
        if session.isRunning { return }
        let go = { self.queue.async { self.configure() } }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            go()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { go() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        // 护航模式用激光雷达相机（带深度）；否则用多摄虚拟设备（光学变焦档位全）
        let dev: AVCaptureDevice?
        if wantsDepth, let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
            dev = lidar
        } else {
            dev = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        guard let dev, let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        device = dev
        if !session.outputs.contains(where: { $0 === photoOutput }), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if !session.outputs.contains(where: { $0 === videoOutput }), session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }
        // 深度流：只在护航模式下挂
        if wantsDepth {
            if !session.outputs.contains(where: { $0 === depthOutput }), session.canAddOutput(depthOutput) {
                depthOutput.isFilteringEnabled = true          // 时域平滑，抗噪
                depthOutput.setDelegate(self, callbackQueue: videoQueue)
                session.addOutput(depthOutput)
            }
        } else if session.outputs.contains(where: { $0 === depthOutput }) {
            session.removeOutput(depthOutput)
            smoothedNear = 0
        }
        // 竖屏方向：实时帧和照片都转正
        for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }

        // 镜头档位：虚拟多摄的切换倍率（14 Pro：factor 1=0.5x 超广角，2=1x 主摄，6=3x 长焦）
        var p: [(String, CGFloat)] = []
        var base: CGFloat = 1
        let sw = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        if sw.count >= 2 {
            p = [("0.5", 1), ("1", sw[0]), ("2", sw[0] * 2), ("3", sw[1])]
            base = sw[0]
        } else if sw.count == 1 {
            p = [("0.5", 1), ("1", sw[0]), ("2", sw[0] * 2)]
            base = sw[0]
        } else {
            p = [("1", 1), ("2", 2), ("3", 3)]
        }
        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = base
            dev.unlockForConfiguration()
        } catch {}
        let running = session.isRunning
        DispatchQueue.main.async {
            self.isRunning = running
            self.presets = p
            self.zoomLabel = "1"
            self.torchOn = false
        }
    }

    /// 切换镜头焦段（"0.5"/"1"/"2"/"3"）
    func setZoom(label: String) {
        let want = label.replacingOccurrences(of: "×", with: "")
        queue.async {
            guard let dev = self.device else { return }
            let all = DispatchQueue.main.sync { self.presets }
            guard let hit = all.first(where: { $0.label == want }) ?? all.first(where: { $0.label == "1" }) else { return }
            do {
                try dev.lockForConfiguration()
                dev.ramp(toVideoZoomFactor: min(hit.factor, dev.maxAvailableVideoZoomFactor), withRate: 8)
                dev.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomLabel = hit.label }
            } catch {}
        }
    }

    /// 手电筒（画面太暗时她会要求打开）
    func setTorch(_ on: Bool) {
        queue.async {
            guard let dev = self.device, dev.hasTorch else { return }
            do {
                try dev.lockForConfiguration()
                dev.torchMode = on ? .on : .off
                dev.unlockForConfiguration()
                DispatchQueue.main.async { self.torchOn = on }
            } catch {}
        }
    }

    // MARK: - 拍照（look_closely 用的高清照片）

    func capture(completion: @escaping (Data?) -> Void) {
        queue.async {
            guard self.session.isRunning else { DispatchQueue.main.async { completion(nil) }; return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced   // 读字够用，比 quality 快近 1 秒
            self.pendingLock.lock(); self.pending[settings.uniqueID] = completion; self.pendingLock.unlock()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        pendingLock.lock(); let done = pending.removeValue(forKey: photo.resolvedSettings.uniqueID); pendingLock.unlock()
        DispatchQueue.main.async { done?(data) }
    }

    // MARK: - 实时帧

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard wantsSnapshots, now.timeIntervalSince(lastSnapshot) > 1.0,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSnapshot = now
        guard let snap = jpeg(CIImage(cvPixelBuffer: pb), maxWidth: 640) else { return }
        DispatchQueue.main.async { self.onSnapshot?(snap) }
    }

    // MARK: - 深度（护航模式的障碍测距）

    /// 取画面中央 40% 窗口的最近距离（10 分位，抗单点噪声），EMA 平滑后回调（约 10Hz）
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastDepth) > 0.1 else { return }
        lastDepth = now
        let data = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let pb = data.depthDataMap
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var vals: [Float] = []
        vals.reserveCapacity(256)
        let x0 = Int(Double(w) * 0.3), x1 = Int(Double(w) * 0.7)
        let y0 = Int(Double(h) * 0.3), y1 = Int(Double(h) * 0.7)
        let step = max(1, (x1 - x0) / 14)
        var y = y0
        while y < y1 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            var x = x0
            while x < x1 {
                let v = row[x]
                if v.isFinite, v > 0.1, v < 8 { vals.append(v) }
                x += step
            }
            y += step
        }
        guard vals.count > 10 else { return }
        vals.sort()
        let near = vals[max(0, vals.count / 10)]
        smoothedNear = smoothedNear == 0 ? near : smoothedNear * 0.6 + near * 0.4
        let d = smoothedNear
        DispatchQueue.main.async { self.onObstacle?(d) }
    }

    /// 缩成宽 maxWidth 的 JPEG（实时帧协议限制 base64 ≤ 256KB）
    private func jpeg(_ image: CIImage, maxWidth: CGFloat, quality: CGFloat = 0.7) -> Data? {
        let s = min(1, maxWidth / max(image.extent.width, 1))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }

    /// 照片原图缩到 maxWidth 宽（给视觉模型细看，兼顾清晰和体积）
    static func downscale(_ data: Data, maxWidth: CGFloat, quality: CGFloat = 0.72) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let w = img.size.width * img.scale
        if w <= maxWidth { return img.jpegData(compressionQuality: quality) }
        let size = CGSize(width: maxWidth, height: img.size.height * maxWidth / img.size.width)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: quality)
    }
}
