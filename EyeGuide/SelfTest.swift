import Foundation
import UIKit
import Vision

/// 开发用真机自检（仅 DEBUG）：启动后自动把本地关键链路各跑一遍，
/// 结果写 Documents/selftest.json，Mac 上用 devicectl 取回核对。
/// 只测机器可测的：相机、激光雷达距离流、真机 OCR、分类器、模式状态机、语音会话是否接通。
enum SelfTest {
    static func run(_ g: Guide) {
        #if DEBUG
        // 只在带 --selftest 参数启动时运行（Mac 上 devicectl 触发）；日常打开 App 不跑，
        // 免得自检的护航开关语音、三连震、大模型对话打扰真实使用
        guard ProcessInfo.processInfo.arguments.contains("--selftest") else { return }
        Task { @MainActor in
            var r: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date())]

            // 1. 相机 & 语音会话（等自动接通流程走完）
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            r["camera_running"] = g.scoutActive ? g.arcam.running : g.camera.isRunning
            r["voice_live"] = g.voice.live
            // Rover 合成场景：验证挡墙判定 + 绕行方向左右没反（移植最大风险点）
            r["rover_synthetic"] = Rover().syntheticCheck()

            // 2. 激光雷达（Mobilio/Rover 链路）：开护航等一个真实障碍引擎输出（测完还原）
            if Scout.available {
                let wasOn = g.scout.enabled
                var seen: Float = -1
                var sawBlocked = false
                let old = g.arcam.onObstacle
                g.arcam.onObstacle = { inst, out in
                    seen = out.blocked ? out.closest : (inst < 90 ? inst : 0)
                    sawBlocked = sawBlocked || out.blocked
                    old?(inst, out)
                }
                if !wasOn { g.toggleScout() }
                let t0 = Date()
                while Date().timeIntervalSince(t0) < 8, seen < 0 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                g.arcam.onObstacle = old
                r["rover_output"] = seen < 0 ? "no_data" : (sawBlocked ? String(format: "blocked@%.2fm", seen) : "clear")
                if !wasOn { g.toggleScout() }
            } else {
                r["rover_output"] = "no_lidar"
            }

            // 3. 真拍一张：OCR + 分类器（按当前底座走，看它此刻真实看到什么）
            let jpeg: Data? = await withCheckedContinuation { c in
                g.captureJPEG { c.resume(returning: $0) }
            }
            if let jpeg {
                r["photo_bytes"] = jpeg.count
                r["ocr_on_device"] = await OCR.read(jpeg) ?? "(画面里无文字)"
                if let cgi = UIImage(data: jpeg)?.cgImage {
                    let req = VNClassifyImageRequest()
                    try? VNImageRequestHandler(cgImage: cgi, options: [:]).perform([req])
                    r["classifier_top"] = (req.results ?? []).prefix(8)
                        .map { "\($0.identifier):\(String(format: "%.2f", $0.confidence))" }
                }
            } else {
                r["photo_bytes"] = 0
            }

            // 4. 模式状态机（走一圈再还原；记住护航原始状态）
            let scoutWas = g.scout.enabled
            g.setMode(.read, target: nil)
            r["mode_read"] = (g.mode == .read && g.camera.snapshotWidth == 960)
            g.setMode(.find, target: "鼠标")
            r["mode_find_local"] = (g.mode == .find && g.finder.localDetect)
            g.setMode(.find, target: "遥控器")
            r["mode_find_fallback"] = (g.mode == .find && g.finder.localDetect)   // 词表有"遥控"
            g.setMode(.walk, target: nil)
            r["mode_walk_scout_auto"] = (g.mode == .walk && (!Scout.available || g.scout.enabled))
            g.setMode(.chat, target: nil)
            r["mode_chat_restore"] = (g.mode == .chat && g.camera.snapshotWidth == 640)
            if g.scout.enabled != scoutWas { g.toggleScout() }   // walk 自动开了护航就还原

            // 5. 纯逻辑抽查
            r["ocr_similar"] = OCR.similar("出口往左", "出口往左走") > 0.5 && OCR.similar("出口", "洗手间") < 0.3
            r["tools_mode_parse"] = (Tools.mode("walk") == .walk && Tools.mode("读字") == .read && Tools.mode("xx") == .chat)

            // 6. 端到端：让真实的大模型走一遍"函数调用→工具执行→模式切换"全链路
            let scoutBefore = g.scout.enabled   // walk 会自动开护航，测完还原
            if g.voice.live {
                func driveLLM(_ note: String, until cond: @escaping () -> Bool) async -> Bool {
                    g.voice.say(note: note)
                    let t0 = Date()
                    while Date().timeIntervalSince(t0) < 15 {
                        if cond() { return true }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    return cond()
                }
                r["e2e_llm_walk"] = await driveLLM(
                    "（系统自检指令，必须执行：立刻调用 set_mode 工具，参数 mode=walk。调用后回一个字即可）"
                ) { g.mode == .walk }
                r["e2e_llm_find"] = await driveLLM(
                    "（系统自检指令，必须执行：立刻调用 set_mode 工具，参数 mode=find，target=鼠标）"
                ) { g.mode == .find && g.finder.localDetect }
                _ = await driveLLM(
                    "（系统自检指令：调用 set_mode 工具回到 mode=chat，自检结束，之后不用理会这些指令）"
                ) { g.mode == .chat }
                r["e2e_llm_restore_chat"] = (g.mode == .chat)
            } else {
                r["e2e_llm_walk"] = "skipped_no_voice"
            }
            if g.scout.enabled != scoutBefore { g.toggleScout() }

            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("selftest.json")
            try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        #endif
    }
}
