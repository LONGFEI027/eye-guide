//
//  StringExtension.swift
//  Pods
//
//  Created by Ginger on 2025/2/24.
//
import Foundation
import CommonCrypto
import UIKit

extension Optional where Wrapped == String {
    public var isNotEmpty: Bool {
        if let string = self {
            return !string.isEmpty
        }
        return false
    }
    
    public var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}


extension String {
    /// 删除前后空格
    public var removeWhitespace: String {
        guard count > 0 else { return "" }
        return trimmingCharacters(in: .whitespaces)
    }
    
    /// 删除所有空格
    public var removeAllWhitespace: String {
        guard count > 0 else { return "" }
        let string = components(separatedBy: .whitespaces)
        return string.joined(separator: "")
    }
}

extension String {
    
    /// json字符串 转 map
    /// - Returns: map
    public func convertTo<T: Any>() -> T? {
        guard let data = self.data(using: .utf8) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data, options: []) as? T
        } catch {
            RGLog.error("Failed to convert the string to map. \(error)")
            return nil
        }
    }
    
    /// JSON字符串 转 Decodable模型
    /// - Returns: 遵循 Decodable 协议的模型
    public func toModel<T: Decodable>() -> T? {
        guard let data = self.data(using: .utf8) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            RGLog.error("Failed to decode JSON to model. \(error)")
            return nil
        }
    }
    
    /// 安全截取子字符串（避免越界）
    /// - Parameters:
    ///   - start: 下标
    ///   - length: 长度
    /// - Returns: 截取的子串
    public func safeSubstring(from start: Int, length: Int? = nil) -> String? {
        guard start >= 0 && start < self.count else { return nil }
        
        let startIndex = self.index(self.startIndex, offsetBy: start)
        
        if let length = length {
            guard length >= 0 else { return nil }
            let end = start + length
            guard end <= self.count else { return nil }
            let endIndex = self.index(startIndex, offsetBy: length)
            return String(self[startIndex..<endIndex])
        } else {
            return String(self[startIndex...])
        }
    }
}

/// 时间格式枚举
public enum FormatterType {
    case `default` // xxxx-xx-xx xx:xx:xx
    case point // xxxx.xx.xx xx:xx
    case dash // xxxx-xx-xx xx:xx
    case text // xxxx年xx月xx日 xx:xx
    case onlyDate // xxxx.xx.xx
    case onlyDash // xxxx-xx-xx
    case onlyText // xxxx年xx月xx日
    case month // xx.xx (月.日)
    case dashMonth // xx-xx (月-日)
    case textMonth // xx月xx日
    case hours // xx:xx （时:分）
    case second // xx:xx:xx（时:分:秒）
    case translateFile // xxxx-xx-xx_xx-xx-xx
    public func formatter() -> String {
        switch self {
        case .default: return "yyyy-MM-dd HH:mm:ss"
        case .point: return "yyyy.MM.dd HH:mm"
        case .dash: return "yyyy-MM-dd HH:mm"
        case .text: return "yyyy年MM月dd日 HH:mm"
        case .onlyDate: return "yyyy.MM.dd"
        case .onlyDash: return "yyyy-MM-dd"
        case .onlyText: return "yyyy年MM月dd日"
        case .month: return "MM.dd"
        case .dashMonth: return "MM-dd"
        case .textMonth: return "MM月dd日"
        case .hours: return "HH:mm"
        case .second: return "HH:mm:ss"
        case .translateFile: return "yyyy-MM-dd_HH-mm-ss"
        }
    }
}
// MARK:  ------------- 时间转换 --------------------
extension String {
    /// 时间戳(毫秒) 转时间
    /// - Parameters:
    ///   - string: 格式
    ///   - timeInterval: 时间戳 Double
    public static func time(formatter string: String, timeInterval: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timeInterval / 1000)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = string
        return formatter.string(from: date)
    }
    
    public static func time(type: FormatterType, timeInterval: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timeInterval / 1000)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = type.formatter()
        return formatter.string(from: date)
    }
    
    /// 时间戳(毫秒) 转时间
    /// - Parameters:
    ///   - string: 格式
    ///   - interval: 时间戳字符串
    public static func time(formatter string: String, stamp interval: String) -> String {
        return Self.time(formatter: string, timeInterval: Double(interval)!)
    }
    
    
    /// 当前时间
    /// - Parameter type: 格式
    public static func currentTime(formatter type: FormatterType) -> String {
        let currentStamp = Date().timeIntervalSince1970 * 1000
        return Self.time(type: type, timeInterval: currentStamp)
    }
    
    /// 时间戳(毫秒) 转 时间
    /// - Parameter type: 格式 类型
    public func time(formatter type: FormatterType = .default) -> String {
        guard count > 0 else { return "" }
        return Self.time(formatter: type.formatter(), stamp: self)
    }
    
    
    /// 时间转时间戳 (秒)
    /// - Parameter type: 格式 类型
    public func timeStamp(_ type: FormatterType = .default) -> TimeInterval {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = type.formatter()
        let last = formatter.date(from: self)
        return last?.timeIntervalSince1970 ?? 0
    }
    
    public func milliseconds(with type: FormatterType = .default) -> TimeInterval {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = type.formatter()
        let last = formatter.date(from: self)
        return (last?.timeIntervalSince1970 ?? 0) * 1000
    }
    public func millisecondsToMinute(with type: FormatterType = .default) -> TimeInterval {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = type.formatter()
        let last = formatter.date(from: self)
        return (last?.timeIntervalSince1970ToMinute ?? 0) * 1000
    }
    
    public func toDate(with type: FormatterType = .default) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = type.formatter()
        return formatter.date(from: self)
    }
    
    
    /// 获取星期
    public var weekDay: String {
        guard count > 0 else { return "" }
        let weekdays = ["", "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")
        calendar.timeZone = timeZone!
        let date = Date.init(timeIntervalSince1970: Double(self)! / 1000)
        let component = calendar.component(.weekday, from: date)
        return weekdays[component]
    }
    
    
    public static func getDateComponents(from timestamp: TimeInterval?) -> (year: Int, month: Int, day: Int)? {
        guard let timestamp = timestamp else { return nil }
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return (year, month, day)
    }
    
    /// 从时间戳字符串获取年、月、日（返回 Int）
    public func getDateComponents() -> (year: Int, month: Int, day: Int)? {
        guard let timestamp = Double(self) else { return nil }
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        
        return (year, month, day)
    }
    
}


extension String {
    public var md5: String {
        guard let data = data(using: .utf8) else { return self }
        return data.md5
    }
}


extension Data {
    public var md5: String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            return CC_MD5(bytes.baseAddress, CC_LONG(count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    public var isValidPhoneNumber: Bool {
        return !isEmpty
        //        let pattern = "^((13[0-9])|(14[0,1,4-9])|(15[0-3,5-9])|(16[2,5,6,7])|(17[0-8])|(18[0-9])|(19[0-3,5-9]))\\d{8}$"
        //        do {
        //            let regex = try NSRegularExpression(pattern: pattern)
        //            let range = NSRange(startIndex..., in: self)
        //            return regex.firstMatch(in: self, range: range) != nil
        //        } catch {
        //            return false
        //        }
    }
    
    public var isValidPassword: Bool {
        // 检查长度
        guard self.count >= 8 && self.count <= 18 else {
            return false
        }
        
        // 检查是否包含空格
        guard !self.contains(" ") else {
            return false
        }
        
        // 定义字符类型检查
        let hasLetter = self.rangeOfCharacter(from: .letters) != nil
        let hasNumber = self.rangeOfCharacter(from: .decimalDigits) != nil
        let hasSymbol = self.rangeOfCharacter(from: .symbols.union(.punctuationCharacters)) != nil
        
        // 至少包含两种类型
        let typeCount = [hasLetter, hasNumber, hasSymbol].filter { $0 }.count
        return typeCount >= 2
    }
}




extension String {
    public func formatWithPositionalArguments(_ args: [String]) -> String {
        var result = self
        for (index, arg) in args.enumerated() {
            let placeholder = "$\(index)"
            result = result.replacingOccurrences(of: placeholder, with: arg)
        }
        return result
    }
}

extension String {
    /// 计算字符串宽度（单行）
    public func width(withFont font: UIFont) -> CGFloat {
        let attributes = [NSAttributedString.Key.font: font]
        let size = (self as NSString).size(withAttributes: attributes)
        return ceil(size.width)
    }
    
    /// 计算字符串高度（可指定最大宽度和多行）
    public func height(withFont font: UIFont, maxWidth: CGFloat = .greatestFiniteMagnitude, lineHeight: CGFloat? = nil) -> CGFloat {
        let constraintRect = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        
        if let lineHeight = lineHeight {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.minimumLineHeight = lineHeight
            paragraphStyle.maximumLineHeight = lineHeight
            attributes[.paragraphStyle] = paragraphStyle
        }
        
        let boundingBox = self.boundingRect(
            with: constraintRect,
            options: .usesLineFragmentOrigin,
            attributes: attributes,
            context: nil
        )
        
        return ceil(boundingBox.height)
    }
    
    /// 计算字符串尺寸（可指定最大宽度和多行）
    public func size(withFont font: UIFont, maxWidth: CGFloat = .greatestFiniteMagnitude, lineHeight: CGFloat? = nil) -> CGSize {
        let constraintRect = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        
        if let lineHeight = lineHeight {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.minimumLineHeight = lineHeight
            paragraphStyle.maximumLineHeight = lineHeight
            
            attributes[.paragraphStyle] = paragraphStyle
        }
        
        let boundingBox = self.boundingRect(
            with: constraintRect,
            options: .usesLineFragmentOrigin,
            attributes: attributes,
            context: nil
        )
        
        return CGSize(width: ceil(boundingBox.width), height: ceil(boundingBox.height))
    }
    
    public func height(withFont font: UIFont, width: CGFloat, lineHeightMultiple: CGFloat = 1.0) -> CGFloat {
        let constraintRect = CGSize(width: width, height: .greatestFiniteMagnitude)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = lineHeightMultiple
        attributes[.paragraphStyle] = paragraphStyle
        
        let boundingBox = self.boundingRect(
            with: constraintRect,
            options: .usesLineFragmentOrigin,
            attributes: attributes,
            context: nil
        )
        return ceil(boundingBox.height)
    }
    
}


extension String {
    
    // MARK: - AES 解密
    
    /// AES 解密
    /// - Parameters:
    ///   - key: 密钥字符串
    ///   - iv: 初始化向量字符串 (可选)
    ///   - keySize: 密钥大小 (128, 192, 256)
    /// - Returns: 解密后的字符串
    public func aesDecrypt(key: String) -> String? {
        guard let data = Data(hexString: self) else {
            return nil
        }
        
        // 确保 key 字符长度为 32 位，不足则末尾补 0
        var paddedKey = key
        if paddedKey.count < 32 {
            paddedKey += String(repeating: "0", count: 32 - paddedKey.count)
        } else if paddedKey.count > 32 {
            paddedKey = String(paddedKey.prefix(32))
        }
        guard let keyData = paddedKey.data(using: .utf8),
              let decryptedData = performCryptOperation(data: data,
                                                        key: keyData,
                                                        operation: CCOperation(kCCDecrypt)) else {
            return nil
        }
        return String(data: decryptedData, encoding: .utf8)
    }
    
    // MARK: - 私有 AES 加密/解密方法
    func performCryptOperation(
        data: Data,
        key: Data,
        operation: CCOperation
    ) -> Data? {
        let blockSize = kCCBlockSizeAES128
        let bufferSize = data.count + blockSize
        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)
        var cryptLength = 0
        
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    dataBytes.baseAddress,
                    data.count,
                    &outputBuffer,
                    bufferSize,
                    &cryptLength
                )
            }
        }
        
        guard status == kCCSuccess else {
            return nil
        }
        
        return Data(bytes: outputBuffer, count: cryptLength)
    }
}

// Data 扩展，用于获取前缀
extension Data {
    func prefix(_ length: Int) -> Data {
        return self.subdata(in: 0..<length)
    }
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}

extension String {
    /// 转属性字符串
    public func toAttributedString(font: UIFont,
                                   textColor: UIColor,
                                   lineHeightMultiple: CGFloat)
    -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = font.lineHeight * lineHeightMultiple
        paragraphStyle.maximumLineHeight = font.lineHeight * lineHeightMultiple
        let baselineOffset = (font.lineHeight * lineHeightMultiple - font.lineHeight) / 2
        return NSAttributedString(string: self, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: baselineOffset
        ])
    }
    
    public func toAttributedString(font: UIFont,
                            textColor: UIColor,
                            lineHeight: CGFloat)
    -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        let attributeString = NSMutableAttributedString(string: self, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: (paragraphStyle.minimumLineHeight - font.lineHeight) / 4
        ])
        return attributeString
    }
    
}

// MARK: - 多语言标签解析
extension String {
    /// 解析多语言标签文本，返回标签名和内容的映射
    /// - Returns: 返回格式如 ["zh": "简体中文内容", "en": "English content"]
    public func parseLanguageTags() -> [String: String]? {
        var result: [String: String] = [:]
        
        // 修复正则表达式：支持大小写字母和连字符
        let pattern = "<([a-zA-Z-]+)>([\\s\\S]*?)</\\1>"
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(startIndex..., in: self)
            let matches = regex.matches(in: self, options: [], range: range)
            
            for match in matches {
                if match.numberOfRanges >= 3 {
                    // 获取标签名
                    let tagRange = match.range(at: 1)
                    let tagName = (self as NSString).substring(with: tagRange)
                    
                    // 获取标签内容
                    let contentRange = match.range(at: 2)
                    let content = (self as NSString).substring(with: contentRange)
                    
                    // 去除首尾空白字符
                    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    result[tagName] = trimmedContent
                }
            }
            if result.isEmpty { return nil }
        } catch {
            RGLog.error("Failed to parse language tags: \(error)")
            return nil
        }
        
        return result
    }
}

extension String {
    public func toDictionary() -> [String: Any]? {
        // 1. 将字符串转换为Data
        guard let jsonData = data(using: .utf8) else {
            print("JSON字符串编码失败（非UTF-8格式）")
            return nil
        }
        
        // 2. 反序列化JSON数据
        do {
            let jsonObject = try JSONSerialization.jsonObject(
                with: jsonData,
                options: []
            )
            
            // 3. 验证是否为字典类型
            guard let dictionary = jsonObject as? [String: Any] else {
                print("JSON内容不是字典类型（可能是数组或其他类型）")
                return nil
            }
            
            return dictionary
        } catch {
            // 处理JSON格式错误
            print("JSON解析失败：\(error.localizedDescription)")
            return nil
        }
    }
}

extension String {
    /// 检查字符串是否包含emoji
    public func containsEmoji() -> Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x1F600...0x1F64F, // Emoticons
                0x1F300...0x1F5FF, // Misc Symbols and Pictographs
                0x1F680...0x1F6FF, // Transport and Map
                0x1F1E0...0x1F1FF, // Regional indicator symbols
                0x2600...0x26FF,   // Misc symbols
                0x2700...0x27BF,   // Dingbats
                0xFE00...0xFE0F,   // Variation Selectors
                0x1F900...0x1F9FF, // Supplemental Symbols and Pictographs
                0x1F018...0x1F270, // Various other emoji ranges
                0x238C...0x2454,   // Misc symbols
                0x20D0...0x20FF,   // Combining Diacritical Marks for Symbols
                0xFE20...0xFE2F:   // Combining Half Marks
                return true
            default:
                continue
            }
        }
        return false
    }
}


extension String {
    /// 检查是否具有有效的文件扩展名
    public var hasValidExtension: Bool {
        let fileName = URL(fileURLWithPath: self).lastPathComponent
        let ext = (fileName as NSString).pathExtension
        
        // 有效扩展名规则：1-10个字母、数字或连字符
        let pattern = "^[a-zA-Z0-9-]{1,10}$"
        return !ext.isEmpty && ext.range(of: pattern, options: .regularExpression) != nil
    }
    
    /// 确保文件具有指定的扩展名（只在没有有效扩展名时添加）
    public func withExtension(_ ext: String, onlyIfInvalid: Bool = true) -> String {
        let fileName = URL(fileURLWithPath: self).lastPathComponent
        let desiredExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        
        // 分离文件名和扩展名
        let nsString = fileName as NSString
        let nameWithoutExt = nsString.deletingPathExtension
        let currentExt = nsString.pathExtension
        
        // 如果已经有有效扩展名且要求只在无效时添加，则保留原扩展名
        if onlyIfInvalid && self.hasValidExtension {
            return fileName
        }
        
        // 添加或替换扩展名
        if currentExt.lowercased() == desiredExt.lowercased() {
            return fileName
        } else {
            return desiredExt.isEmpty ? nameWithoutExt : "\(nameWithoutExt).\(desiredExt)"
        }
    }
    
    /// 确保文件具有 .txt 扩展名（只在没有有效扩展名时添加）
    public var withTxtExtension: String {
        return self.withExtension("txt", onlyIfInvalid: true)
    }
    
    /// 强制使用 .txt 扩展名（无论原扩展名是否有效）
    public var forceTxtExtension: String {
        return self.withExtension("txt", onlyIfInvalid: false)
    }
}


extension String {
    /// 完全脱敏
    func fullyMasked(maskChar: Character = "*") -> String {
        return String(repeating: maskChar, count: self.count)
    }
    /// 字符串脱敏
    public func desensitize(start: Int, end: Int, maskChar: Character = "*") -> String {
        let totalLength = self.count
        
        // 安全检查
        guard totalLength > 0 else { return "" }
        guard start >= 0 && end >= 0 else { return self.fullyMasked(maskChar: maskChar) }
        guard totalLength > start + end else {
            // 如果字符串长度不足以脱敏，返回全脱敏
            return self.fullyMasked(maskChar: maskChar)
        }
        
        let startIndex = self.index(self.startIndex, offsetBy: start)
        let endIndex = self.index(self.endIndex, offsetBy: -end)
        
        let startPart = String(self[..<startIndex])
        let endPart = String(self[endIndex...])
        let maskCount = self.distance(from: startIndex, to: endIndex)
        
        // 确保maskCount不为负
        guard maskCount > 0 else {
            return startPart + endPart
        }
        
        let maskPart = String(repeating: maskChar, count: maskCount)
        return startPart + maskPart + endPart
    }
}
