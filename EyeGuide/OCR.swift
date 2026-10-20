import Foundation
import Vision
import UIKit

/// 本地即时读字（iOS 自带 Vision OCR，支持中文，离线、亚秒级）。
/// look_closely 的快路径：牌子上字够多就直接把 OCR 原文交给她读，
/// 省掉"上传→云端视觉模型"的好几秒；字太少或要"理解画面"时仍走云端。
enum OCR {
    static func read(_ jpeg: Data) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let img = UIImage(data: jpeg)?.cgImage else { cont.resume(returning: nil); return }
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.recognitionLanguages = ["zh-Hans", "en-US"]
                req.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: img, options: [:])
                guard (try? handler.perform([req])) != nil else { cont.resume(returning: nil); return }
                let lines = (req.results ?? [])
                    .compactMap { $0.topCandidates(1).first }
                    .filter { $0.confidence > 0.3 }
                    .map { $0.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }

    /// 问题是不是"读字类"（快路径只在这类问题上启用，免得把海报文字当成环境描述）
    static func isReadingQuestion(_ q: String) -> Bool {
        let keys = ["写", "字", "牌", "号", "线", "标", "读", "价", "名", "门", "说明", "几路", "站", "单", "票", "日期", "电话"]
        return keys.contains { q.contains($0) }
    }
}
