import Foundation
import Vision
import UIKit

/// 本地即时读字（iOS 自带 Vision OCR，支持中文，离线、亚秒级）。
/// look_closely 的快路径：牌子上字够多就直接把 OCR 原文交给她读，
/// 省掉"上传→云端视觉模型"的好几秒；字太少或要"理解画面"时仍走云端。
enum OCR {
    /// 识别结果：全文 + 每行文字的框（Vision 归一化坐标，原点左下，相对识别图）
    struct Reading {
        let text: String
        let boxes: [CGRect]
    }

    static func read(_ jpeg: Data) async -> String? { await readDetailed(jpeg)?.text }

    static func readDetailed(_ jpeg: Data) async -> Reading? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let img = UIImage(data: jpeg)?.cgImage else { cont.resume(returning: nil); return }
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.recognitionLanguages = ["zh-Hans", "en-US"]
                req.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: img, options: [:])
                guard (try? handler.perform([req])) != nil else { cont.resume(returning: nil); return }
                let accepted = (req.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.3 }
                let lines = accepted.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: text.isEmpty ? nil : Reading(text: text, boxes: accepted.map(\.boundingBox)))
            }
        }
    }

    /// 两段文字的相似度（字二元组重叠率）——读字模式去重：同一块牌子别反复念
    static func similar(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let cs = Array(s.filter { !$0.isWhitespace && !$0.isPunctuation })
            guard cs.count > 1 else { return [] }
            var g = Set<String>()
            for i in 0..<(cs.count - 1) { g.insert(String(cs[i]) + String(cs[i + 1])) }
            return g
        }
        let A = grams(a), B = grams(b)
        guard !A.isEmpty, !B.isEmpty else { return 0 }
        return Double(A.intersection(B).count) / Double(min(A.count, B.count))
    }

    /// 问题是不是"读字类"（快路径只在这类问题上启用，免得把海报文字当成环境描述）
    static func isReadingQuestion(_ q: String) -> Bool {
        let keys = ["写", "字", "牌", "号", "线", "标", "读", "价", "名", "门", "说明", "几路", "站", "单", "票", "日期", "电话"]
        return keys.contains { q.contains($0) }
    }
}
