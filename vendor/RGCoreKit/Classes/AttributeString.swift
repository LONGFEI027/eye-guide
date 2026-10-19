//
//  AttributeString.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/5/10.
//

import Foundation
import UIKit


extension NSAttributedString {
    /// 创建富文本字符串，将指定子串设置为蓝色
    /// - Parameters:
    ///   - fullString: 完整的字符串
    ///   - subStrings: 需要设置为蓝色的子串数组
    ///   - linkKeys: 为高亮子串添加link信息
    ///   - baseColor: 基础颜色（默认为黑色）
    ///   - highlightColor: 高亮颜色（默认为蓝色）
    ///   - highlightFont: 高亮字体（可选，如果为nil则使用基础font）
    ///   - highlightAllMatches: 匹配到之后是否要接着匹配
    /// - Returns: 格式化后的富文本字符串
    public static func createHighlightedString(
        fullString: String,
        subStrings: [String],
        linkKeys: [String]? = nil,
        underlineKeys: [String]? = nil,
        font: UIFont,
        baseColor: UIColor = .black,
        highlightColor: UIColor = .blue,
        highlightFont: UIFont? = nil,
        highlightAllMatches: Bool = false
    ) -> NSMutableAttributedString {
        let attributedString = NSMutableAttributedString(
            string: fullString,
            attributes: [
                .font: font,
                .foregroundColor: baseColor
            ]
        )
        for (index, subString) in subStrings.enumerated() {
            var searchRange = NSRange(location: 0, length: fullString.utf16.count)
            while true {
                let range = (fullString as NSString).range(of: subString, options: [], range: searchRange)
                if range.location == NSNotFound {
                    break
                }
                attributedString.addAttribute(
                    .foregroundColor,
                    value: highlightColor,
                    range: range
                )
                if let highlightFont = highlightFont {
                    attributedString.addAttribute(
                        .font,
                        value: highlightFont,
                        range: range
                    )
                }
                if let key = linkKeys?[safe: index] {
                    attributedString.addAttribute(
                        .link,
                        value: key,
                        range: range
                    )
                }
                if let key = underlineKeys?[safe: index] {
                    attributedString.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
                if !highlightAllMatches {
                    break
                }
                searchRange = NSRange(location: range.location + range.length, length: fullString.utf16.count - (range.location + range.length))
            }
        }
        return attributedString
    }
}


extension NSAttributedString {
    public func height(withWidth width: CGFloat) -> CGFloat {
        let constraintRect = CGSize(width: width, height: .greatestFiniteMagnitude)
        let boundingBox = boundingRect(with: constraintRect,
                                       options: [.usesLineFragmentOrigin, .usesFontLeading, .usesDeviceMetrics],
                                      context: nil)
        return ceil(boundingBox.height)
    }
    
    public func width(withHeight height: CGFloat) -> CGFloat {
        let constraintRect = CGSize(width: .greatestFiniteMagnitude, height: height)
        let boundingBox = boundingRect(with: constraintRect,
                                       options: [.usesLineFragmentOrigin, .usesFontLeading, .usesDeviceMetrics],
                                      context: nil)
        return ceil(boundingBox.width)
    }
}
