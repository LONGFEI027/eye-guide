import Foundation

/// 实时语音通道：连茉兔服务器的实时桥（纯透传到百炼 omni-realtime），协议和 photo-coach 相同。
/// 回复时机由客户端决定（create_response:false）：
/// - 你开口（speech_started）→ 她立刻闭嘴（AEC 保证听到的是你，不是她自己的回声）
/// - 你说完（speech_stopped + 转写）→ 回声/杂音/嗯哦不理，其余才让她回答
/// - 回复排队：协议不允许并发 response.create，她说话期间的新回复排到说完再发
final class VoiceLink: NSObject, ObservableObject {
    @Published var live = false                  // 通话中
    @Published var status = ""                   // 连接状态/错误提示
    /// 对话轮次（驱动界面的"在听/在想"提示）
    enum Turn { case idle, listening, thinking }
    @Published var turn: Turn = .idle

    let audio = AudioEngine()
    var onCaption: ((String) -> Void)?           // 她的字幕（增量累计）
    var onUserText: ((String) -> Void)?          // 你说的话（转写）
    var onAssistantDone: ((String) -> Void)?     // 她完整说完的一句
    var onNeedLogin: (() -> Void)?
    /// 她调用了工具：(工具名, 参数, call_id, 这一轮她有没有先说话)
    var onToolCall: ((String, [String: Any], String, Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var active = false                   // 有回复在生成（含"已排队即将生成"）
    private var dropResp = false                 // 这条回复已被打断，剩余音频丢弃
    private var userTalking = false
    private var botText = ""                     // 当前这条回复的全文（含被丢弃的，回声比对用）
    private var lastBot = ""                     // 上一条回复全文
    private var pendingCreates: [() -> Void] = []
    private var pendingTurn = false
    private var turnGen = 0
    private var lastTr: (text: String, at: Date)?
    private var instructions = ""
    private var audioSent = false                // 协议要求：图像帧必须在音频之后
    private var calls: [(name: String, args: String, id: String)] = []

    /// 对方正在说话（服务端检测到人声还没停）
    var userSpeaking: Bool { userTalking }

    /// 她正在说话或正在生成回复
    var isBusy: Bool { active || audio.speaking || !pendingCreates.isEmpty }

    /// 镜头画面给模型看（每秒一张）：随你下一句话一起提交进对话，她就"看得见"了
    func sendImage(_ jpeg: Data) {
        guard ready, audioSent else { return }
        sendEvent(["type": "input_image_buffer.append", "image": jpeg.base64EncodedString()])
    }

    private static let backchannel = "^[嗯哦啊呃唔额对是好行哈呵]{1,3}[。！？!?~～…]*$"

    // MARK: - 开关

    func start(instructions: String) {
        stop()
        self.instructions = instructions
        status = "连接中…"
        let t = URLSession.shared.webSocketTask(with: Config.realtimeURL)   // shared 会话自动带登录 Cookie
        task = t
        t.resume()
        receive()
        sendEvent(["type": "session.update", "session": [
            "modalities": ["text", "audio"],
            "voice": Config.voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "instructions": instructions,
            "tools": Tools.schema,
            "input_audio_transcription": ["model": "gummy-realtime-v1"],
            "turn_detection": ["type": "server_vad", "threshold": 0.2, "silence_duration_ms": 500,
                               "create_response": false, "interrupt_response": false],
        ]])
        do {
            try audio.start()
        } catch {
            status = "麦克风启动失败：\(error.localizedDescription)"
            stop()
            return
        }
        audio.onMicChunk = { [weak self] pcm in
            self?.sendEvent(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
            self?.audioSent = true
        }
    }

    func stop() {
        audio.onMicChunk = nil
        audio.stop()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        DispatchQueue.main.async {
            self.live = false; self.ready = false; self.active = false; self.audioSent = false
            self.dropResp = false; self.userTalking = false
            self.pendingCreates = []; self.pendingTurn = false
            self.botText = ""; self.lastBot = ""; self.status = ""; self.turn = .idle
        }
    }

    /// 更新她的上下文（位置变化等），通话中随时可调
    func refreshInstructions(_ text: String) {
        instructions = text
        guard ready else { return }
        sendEvent(["type": "session.update", "session": ["instructions": text]])
    }

    /// 内部指令：让她按提示主动说一句（不显示、不算用户发言）
    func say(note: String) {
        guard ready else { return }
        createResponse(note: note)
    }

    /// 系统事件：写进对话让她知道（【系统事件】开头，她被告知这不是对方说的话）；speak=要不要她开口
    func event(_ text: String, speak: Bool) {
        guard ready else { return }
        if speak {
            createResponse(note: "【系统事件】" + text)
        } else {
            sendEvent(["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "【系统事件】" + text]]]])
        }
    }

    /// 工具执行结果交还给她；speak=让她据此说一句（细看的结果要说，开手电这类她已经说过就不用）
    func toolResult(callId: String, output: String, speak: Bool) {
        guard ready, !callId.isEmpty else { return }
        let send = { [weak self] in
            guard let self else { return }
            self.sendEvent(["type": "conversation.item.create",
                            "item": ["type": "function_call_output", "call_id": callId, "output": output]])
            if speak { self.createResponse() } else { self.runNext() }
        }
        // 她还在生成回复时先排队，等这条说完再交结果
        if active { pendingCreates.append(send) } else { send() }
    }

    /// 排队里下一件事（不产生回复的事做完后，要手动接力，否则队列会卡住）
    private func runNext() {
        guard !active, !pendingCreates.isEmpty else { return }
        pendingCreates.removeFirst()()
    }

    // MARK: - 收发

    private func sendEvent(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    /// 唯一的回复入口：她正说着/正生成时排队，说完再发（协议不允许并发回复）
    private func createResponse(note: String? = nil) {
        let run = { [weak self] in
            guard let self, self.ready else { return }
            self.active = true
            if !self.audio.speaking, self.turn != .thinking { self.turn = .thinking }
            if let note {
                self.sendEvent(["type": "conversation.item.create", "item": ["type": "message", "role": "user",
                                "content": [["type": "input_text", "text": note]]]])
            }
            self.sendEvent(["type": "response.create"])
        }
        if active { pendingCreates.append(run) } else { run() }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg,
                   let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    DispatchQueue.main.async { self.handle(obj) }
                }
                self.receive()
            case .failure:
                DispatchQueue.main.async {
                    if self.live { self.status = "连接断开了，再点一次按钮重连" }
                    self.stop()
                }
            }
        }
    }

    // MARK: - 协议处理（全部在主线程）

    private func handle(_ d: [String: Any]) {
        switch d["type"] as? String ?? "" {
        case "session.updated":
            if !ready {
                ready = true; live = true; status = ""
                say(note: "（系统提示，对方看不见屏幕：语音刚接通，你是视觉助手小路，用不超过15个字打个招呼说你在、让对方把手机镜头朝前，别提\"系统\"）")
            }

        case "input_audio_buffer.speech_started":
            userTalking = true
            if turn != .listening { turn = .listening }
            audio.hush()                          // 你开口 → 她立刻闭嘴
            if active { dropResp = true }
            pendingCreates.removeAll()            // 排队中的旧回复也不要了
            turnGen += 1

        case "input_audio_buffer.speech_stopped":
            userTalking = false
            pendingTurn = true
            if turn == .listening { turn = .thinking }
            if let tr = lastTr, Date().timeIntervalSince(tr.at) < 2.5 {
                lastTr = nil
                handleTurn(tr.text)
            } else {
                let gen = turnGen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.pendingTurn, self.turnGen == gen else { return }
                    self.handleTurn("")           // 转写迟迟不来：多半是杂音
                }
            }

        case "conversation.item.input_audio_transcription.completed":
            let tr = (d["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if tr.count >= 4, Self.sim(tr, lastBot + " " + botText) >= 0.5 {
                pendingTurn = false; lastTr = nil                          // 她自己的回声：当没听见
                return
            }
            if !tr.isEmpty { onUserText?(tr) }
            if pendingTurn { handleTurn(tr) } else { lastTr = (tr, Date()) }

        case "response.created":
            active = true
            dropResp = userTalking                // 她还没出声你又开口了 → 这条直接作废
            if !botText.isEmpty { lastBot = botText }
            botText = ""
            calls = []

        case "response.function_call_arguments.done":
            calls.append((d["name"] as? String ?? "", d["arguments"] as? String ?? "{}", d["call_id"] as? String ?? ""))

        case "response.audio_transcript.delta":
            botText += d["delta"] as? String ?? ""
            if !dropResp { onCaption?(botText) }

        case "response.audio.delta":
            guard !dropResp, let b64 = d["delta"] as? String, let pcm = Data(base64Encoded: b64) else { return }
            if turn != .idle { turn = .idle }
            audio.play(pcm)

        case "response.done":
            active = false
            if turn == .thinking { turn = .idle }
            if !dropResp, !botText.isEmpty { onAssistantDone?(botText) }
            dropResp = false
            let spoke = !botText.isEmpty
            for c in calls {                      // 工具在这条回复结束后再执行（结果回来时协议状态干净）
                let args = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8))) as? [String: Any] ?? [:]
                onToolCall?(c.name, args, c.id, spoke)
            }
            calls = []
            if !pendingCreates.isEmpty {
                let next = pendingCreates.removeFirst()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { next() }
            }

        case "error":
            let msg = ((d["error"] as? [String: Any])?["message"] as? String) ?? ""
            if msg.contains("请先登录") { onNeedLogin?(); stop() }
            else if msg.range(of: "append image|buffer too small", options: [.regularExpression, .caseInsensitive]) != nil { return }   // 帧时序的良性报错
            else if !msg.isEmpty { status = String(msg.prefix(60)) }

        default:
            break
        }
    }

    private func handleTurn(_ transcript: String) {
        pendingTurn = false; lastTr = nil
        if turn == .thinking && !active { turn = .idle }                   // 默认不回应；真要回应时 createResponse 会再设成"在想"
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }                                            // 没听清的杂音：不回应
        if t.range(of: Self.backchannel, options: .regularExpression) != nil { return }   // "嗯/哦"只是应声
        createResponse()
    }

    /// 两段话的相似度（字二元组重叠率）：识别"转写的其实是她自己的回声"
    private static func sim(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let cs = Array(s.filter { !"，。！？、\"'…—~～,.!? \n；;：:".contains($0) })
            guard cs.count > 1 else { return [] }
            var g = Set<String>()
            for i in 0..<(cs.count - 1) { g.insert(String(cs[i]) + String(cs[i + 1])) }
            return g
        }
        let A = grams(a), B = grams(b)
        guard !A.isEmpty, !B.isEmpty else { return 0 }
        return Double(A.intersection(B).count) / Double(min(A.count, B.count))
    }
}
