import Foundation
import Vision
import UIKit

/// 找东西（本地）：用系统自带的图像分类器（免下载模型）在画面左/中/右三个窗口里找目标，
/// 命中就报钟面方向；"人"走专门的人形检测（有框，方向更准）。
/// 词表外的目标返回 false，由大模型看画面来找（降级路径）。
final class Finder {
    /// 中文目标 → 分类器英文词根（匹配用 contains，长词在前防"自行车"命中"车"）
    private static let lexicon: [(zh: String, en: [String])] = [
        ("自行车", ["bicycle", "bike"]), ("红绿灯", ["traffic"]), ("垃圾桶", ["trash", "garbage", "bin"]),
        ("洗衣机", ["washer", "washing"]), ("微波炉", ["microwave"]), ("冰箱", ["refrigerator", "fridge"]),
        ("电脑", ["laptop", "computer", "keyboard"]), ("笔记本", ["laptop", "notebook"]),
        ("手机", ["phone"]), ("电视", ["television", "monitor", "screen"]), ("遥控", ["remote"]),
        ("椅", ["chair", "stool", "seat"]), ("凳", ["stool", "chair"]), ("桌", ["table", "desk"]),
        ("门", ["door"]), ("窗", ["window"]), ("床", ["bed"]), ("沙发", ["sofa", "couch"]),
        ("杯", ["cup", "mug", "glass"]), ("瓶", ["bottle"]), ("碗", ["bowl"]), ("盘", ["plate", "dish"]),
        ("包", ["backpack", "handbag", "bag"]), ("鞋", ["shoe", "boot", "sneaker", "footwear"]),
        ("伞", ["umbrella"]), ("书", ["book"]), ("灯", ["lamp", "chandelier"]), ("剪刀", ["scissors"]),
        ("楼梯", ["stair"]), ("猫", ["cat"]), ("狗", ["dog"]), ("花", ["flower"]), ("植物", ["plant"]),
        ("车", ["car", "vehicle", "truck", "bus"]),
    ]

    private(set) var target: String?
    private var keys: [String] = []

    /// 设定目标。返回 true=本地词表认识，能自己检测；false=交给大模型看画面找
    @discardableResult
    func set(target: String?) -> Bool {
        self.target = target
        keys = []
        guard let t = target, !t.isEmpty else { return false }
        if t.contains("人") { keys = ["__human__"]; return true }
        for entry in Self.lexicon where t.contains(entry.zh) { keys = entry.en; return true }
        return false
    }

    var localDetect: Bool { !keys.isEmpty }

    struct Hit { let direction: String; let confidence: Float }

    /// 扫一帧（640~960px JPEG，1fps 节奏下很便宜）
    func scan(_ jpeg: Data) -> Hit? {
        guard localDetect, let cg = UIImage(data: jpeg)?.cgImage else { return nil }
        if keys == ["__human__"] { return scanHuman(cg) }
        let w = cg.width, h = cg.height
        let windows: [(String, CGRect)] = [
            ("十点方向", CGRect(x: 0, y: 0, width: Int(Double(w) * 0.45), height: h)),
            ("正前方", CGRect(x: Int(Double(w) * 0.275), y: 0, width: Int(Double(w) * 0.45), height: h)),
            ("两点方向", CGRect(x: Int(Double(w) * 0.55), y: 0, width: Int(Double(w) * 0.45), height: h)),
        ]
        var best: Hit?
        for (dir, rect) in windows {
            guard let crop = cg.cropping(to: rect) else { continue }
            let req = VNClassifyImageRequest()
            try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])
            for obs in req.results ?? [] where obs.confidence > 0.25 {
                let id = obs.identifier.lowercased()
                guard keys.contains(where: { id.contains($0) }) else { continue }
                if best == nil || obs.confidence > best!.confidence {
                    best = Hit(direction: dir, confidence: obs.confidence)
                }
            }
        }
        return best
    }

    private func scanHuman(_ cg: CGImage) -> Hit? {
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = true
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        guard let o = (req.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let cx = o.boundingBox.midX
        let dir = cx < 0.38 ? "十点方向" : (cx > 0.62 ? "两点方向" : "正前方")
        return Hit(direction: dir, confidence: o.confidence)
    }
}
