import AVFoundation

/// 语音通话的耳朵和嘴：
/// - 采集：麦克风 → 重采样成 16k 单声道 pcm16，每约 0.1 秒回调一段
/// - 播放：24k pcm16 顺序排播
/// 关键：必须在输入节点上显式启用 voice processing 才有系统级回声消除——
/// 只设 .voiceChat 会话模式是不够的，她的声音会从麦克风灌回来打断她自己。
final class AudioEngine: ObservableObject {
    @Published var speaking = false                  // 她正在出声
    @Published var level: Float = 0                  // 她声音的实时电平（0~1，驱动界面脉动）
    private(set) var aecOn = false
    var onMicChunk: ((Data) -> Void)?
    var onDoneSpeaking: (() -> Void)?                // 她这句话播完了（主线程）

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var scheduled = 0                        // 排播中的缓冲数（主线程维护）

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // allowBluetooth：戴蓝牙耳机（骨传导/气传导）时，声音和麦克风走耳机，不堵耳朵
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        // 不加这句，通话录音期间系统会屏蔽护航的触感震动
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)

        engine.attach(player)
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)   // 回声消除（AEC）真正的开关
            aecOn = true
        } catch {
            aecOn = false
            print("[小路] 回声消除启用失败，退化为普通采集：\(error)")
        }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: micFormat)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { [weak self] buffer, _ in
            self?.pumpMic(buffer)
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.meter(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.scheduled = 0; self.speaking = false; self.level = 0 }
    }

    private func pumpMic(_ buffer: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
        var fed = false
        conv.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        onMicChunk?(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var count = 0
        for i in stride(from: 0, to: n, by: 4) { let v = ch[0][i]; sum += v * v; count += 1 }
        let rms = count > 0 ? sqrtf(sum / Float(count)) : 0
        DispatchQueue.main.async { self.level = self.level * 0.55 + min(1, rms * 7) * 0.45 }
    }

    /// 播一段她的声音（24k pcm16 单声道）
    func play(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<frames { dst[i] = Float(src[i]) / 32768.0 }
        }
        DispatchQueue.main.async {
            self.scheduled += 1
            self.speaking = true
        }
        player.scheduleBuffer(buf) {
            DispatchQueue.main.async {
                self.scheduled = max(0, self.scheduled - 1)
                if self.scheduled == 0, self.speaking {
                    self.speaking = false
                    self.onDoneSpeaking?()
                }
            }
        }
    }

    var isRunning: Bool { engine.isRunning }

    /// 打断：清空排播队列，立刻闭嘴
    func hush() {
        player.stop()
        player.play()
        DispatchQueue.main.async { self.scheduled = 0; self.speaking = false; self.level = 0 }
    }
}
