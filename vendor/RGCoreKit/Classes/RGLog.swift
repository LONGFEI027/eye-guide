//
//  RGLog.swift
//  Pods
//
//  Created by Ginger on 2025/2/20.
//

import Foundation
internal import CocoaLumberjack

public func makeNSError(code: Int, message: String?) -> NSError {
    NSError(domain: "com.RGCoreKit", code: code, userInfo: [NSLocalizedDescriptionKey: message ?? ""])
}

enum RGLogInfoType {
    case api
    case callbackError
    case callbackSucc
}

class RGDOSLogLevelMapper: NSObject, DDOSLogLevelMapper {
    func osLogType(for logFlag: DDLogFlag) -> OSLogType {
        switch logFlag {
        case .error: return .error
        case .warning: return .error
        case .info: return .default
        case .verbose: return .default
        case .debug: return .debug
        default: return .default
        }
    }
}

public class RGLog {
    static var isInitialized = false
    
    // 添加默认的日志格式化器
    private class DefaultLogFormatter: NSObject, DDLogFormatter {
        private let dateFormatter: DateFormatter
        
        override init() {
            dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.calendar = Calendar(identifier: .gregorian)
        }
        
        public func format(message logMessage: DDLogMessage) -> String? {
            let level = logMessage.flag
            let levelString: String
            switch level {
            case .error: levelString = "❌ERROR"
            case .warning: levelString = "⚠️WARN"
            case .info:
                if let infoType = logMessage.representedObject as? RGLogInfoType {
                    switch infoType {
                    case .api:
                        levelString = "📌API"
                    case .callbackError:
                        levelString = "❌ERROR"
                    case .callbackSucc:
                        levelString = "✅SUCC"
                    }
                } else {
                    levelString = "👉🏻INFO"
                }
            case .debug: levelString = "⚙️DEBUG"
            case .verbose: levelString = "📃VERBOSE"
            default: levelString = "UNKNOWN"
            }
            
            let timestamp = dateFormatter.string(from: logMessage.timestamp)
            return "[RGLog] [\(timestamp)] [\(levelString)] [\(logMessage.threadID)] [\(logMessage.fileName):\(logMessage.line) \(logMessage.function ?? "")] > \(logMessage.message)"
        }
    }
    
    /// 初始化日志模块
    static public func setup(_ release: Bool) {
        if isInitialized { return }
        isInitialized = true
        
        // 设置全局日志级别
        if release {
            dynamicLogLevel = .info
        } else {
            dynamicLogLevel = .all
        }
        
        // 创建默认格式化器
        let formatter = DefaultLogFormatter()
        
        // 设置控制台日志
        if !release {
            let logger = DDOSLogger(logLevelMapper: RGDOSLogLevelMapper())
            logger.logFormatter = formatter
            DDLog.add(logger)
        }
        
        // 设置文件日志
#if targetEnvironment(simulator)
        let fileLogger = DDFileLogger()
#else
        var fileLogger = DDFileLogger()
        if let documentsDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory,.userDomainMask, true).first {
            let customLogPath = "\(documentsDirectory)/RGLog"
            fileLogger = DDFileLogger(logFileManager: DDLogFileManagerDefault.init(logsDirectory: customLogPath))
        }
#endif
        fileLogger.logFormatter = formatter
        fileLogger.logFileManager.maximumNumberOfLogFiles = 10
        fileLogger.logFileManager.logFilesDiskQuota = 10 * 10 * 1024 * 1024
        fileLogger.maximumFileSize = release ? 1024 * 1024 * 5 : 1024 * 1024 * 8
        fileLogger.rollingFrequency = 60 * 60 * 24
        DDLog.add(fileLogger)
    }
    
    static var sensitives: [String] = []
    
    /// 添加敏感词过滤
    static public func addSensitive(_ str: String) {
//        if !sensitives.contains(str) {
//            sensitives.append(str)
//        }
    }
    
    /// 移除敏感词
    static public func removeSensitive(_ str: String) {
        sensitives.removeAll(where: { $0 == str })
    }
    
    /// 日志脱敏
    static private func desensitize(msg: String?) -> String {
        if let msg = msg {
            var target = msg
            sensitives.forEach { sensitive in
                target = desensitize(string: target, sensitive: sensitive)
            }
            return target
        }
        return ""
    }
    
    /// 脱敏字符串，比如将 "appkey:123456789" 脱敏为 "appkey:123***789"
    /// - Parameters:
    ///   - string: 待脱敏的字符串
    ///   - sensitive: 脱敏关键字
    /// - Returns: 脱敏后的字符串
    private static func desensitize(string: String, sensitive: String) -> String {
        // 添加安全检查
        guard !string.isEmpty && !sensitive.isEmpty else {
            return string
        }
        
        let length = sensitive.count
        if length < 3 {
            return string.replacingOccurrences(of: sensitive, with: "***")
        } else {
            let leave = length > 11 ? 4 : length / 3
            // 确保leave值不会导致问题
            let safeLeave = max(0, min(leave, length / 2))
            let template = around(string: sensitive, left: safeLeave, right: safeLeave, template: "*")
            return string.replacingOccurrences(of: sensitive, with: template)
        }
    }
    
    /// 脱敏字符串，比如将 "123456789" 脱敏为 "123***789"
    /// - Parameters:
    ///   - string: 待脱敏的字符串
    ///   - left: 左边显示几个字符
    ///   - right: 右边显示几个字符
    ///   - template: 用什么字符来脱敏，比如 "*"
    /// - Returns: 脱敏后的字符串
    private static func around(string: String, left: Int, right: Int, template: String) -> String {
        // 添加安全检查
        guard !string.isEmpty && !template.isEmpty else {
            return string
        }
        
        let length = string.count
        let safeLeft = max(0, min(left, length))
        let safeRight = max(0, min(right, length))
        
        // 如果左右字符数之和大于等于字符串长度，直接返回脱敏字符串
        if safeLeft + safeRight >= length {
            return String(repeating: template, count: length)
        }
        
        // 使用更安全的方式实现脱敏，避免正则表达式的lookbehind/lookahead问题
        let startIndex = string.startIndex
        let leftEndIndex = string.index(startIndex, offsetBy: safeLeft)
        let rightStartIndex = string.index(startIndex, offsetBy: length - safeRight)
        
        let leftPart = String(string[startIndex..<leftEndIndex])
        let rightPart = String(string[rightStartIndex..<string.endIndex])
        let middleLength = length - safeLeft - safeRight
        
        // 生成中间部分的脱敏字符
        let middlePart = String(repeating: template, count: middleLength)
        
        return leftPart + middlePart + rightPart
    }
    
    /// API调用
    /// - Parameters:
    ///   - params: 参数
    static public func api(_ params: Any? = nil,
                           file: StaticString = #file,
                           function: StaticString = #function,
                           line: UInt = #line) {
        let message = formatMessage(params)
        DDLogInfo(.init(stringLiteral: desensitize(msg: message)), level: .info, file: file, function: function, line: line, tag: RGLogInfoType.api, asynchronous: true)
    }
    
    /// 普通日志
    /// - Parameters:
    ///   - items: 日志信息
    static public func info(_ params: Any? = nil,
                            file: StaticString = #file,
                            function: StaticString = #function,
                            line: UInt = #line) {
        let message = formatMessage(params)
        DDLogInfo(.init(stringLiteral: desensitize(msg: message)), level: .info, file: file, function: function, line: line, asynchronous: true)
    }
    
    /// 比较长的日志，如大段的JSON等，只会在DEBUG模式下打印
    /// - Parameters:
    ///   - message: 日志信息
    static public func verbose(_ params: Any? = nil,
                               file: StaticString = #file,
                               function: StaticString = #function,
                               line: UInt = #line) {
        let message = formatMessage(params)
        DDLogVerbose(.init(stringLiteral: desensitize(msg: message)), level: .verbose, file: file, function: function, line: line, asynchronous: true)
    }
    
    /// 用于DEBUG的日志，只会在DEBUG模式下打印
    /// - Parameters:
    ///   - message: 日志信息
    static public func debug(_ params: Any? = nil,
                             file: StaticString = #file,
                             function: StaticString = #function,
                             line: UInt = #line) {
        let message = formatMessage(params)
        DDLogDebug(.init(stringLiteral: desensitize(msg: message)), level: .debug, file: file, function: function, line: line, asynchronous: true)
    }
    
    /// 警告信息
    /// - Parameters:
    ///   - message: 日志信息
    static public func warn(_ params: Any? = nil,
                            file: StaticString = #file,
                            function: StaticString = #function,
                            line: UInt = #line) {
        let message = formatMessage(params)
        DDLogWarn(.init(stringLiteral: desensitize(msg: message)), level: .warning, file: file, function: function, line: line, asynchronous: true)
    }
    
    /// 错误信息
    /// - Parameters:
    ///   - message: 日志信息
    static public func error(_ params: Any? = nil,
                             file: StaticString = #file,
                             function: StaticString = #function,
                             line: UInt = #line) {
        let message = formatMessage(params)
        DDLogError(.init(stringLiteral: desensitize(msg: message)), level: .error, file: file, function: function, line: line, asynchronous: true)
    }
    
    /// 接口回调信息，如网络请求回调
    /// - Parameters:
    ///   - message: 日志信息
    ///   - succ: 是否调用成功
    ///   - error: 失败的结果
    static public func callback(_ params: Any? = nil,
                                succ: Bool,
                                error: NSError? = nil,
                                file: StaticString = #file,
                                function: StaticString = #function,
                                line: UInt = #line) {
        let message = formatMessage(params)
        if succ {
            DDLogInfo(.init(stringLiteral: desensitize(msg: message)), level: .info, file: file, function: function, line: line, tag: RGLogInfoType.callbackSucc, asynchronous: true)
        } else {
            let msg = "\(message) Code: \(String(describing: error?.code)) Msg: \(String(describing: error?.localizedDescription))"
            DDLogInfo(.init(stringLiteral: desensitize(msg: msg)), level: .info, file: file, function: function, line: line, tag: RGLogInfoType.callbackError, asynchronous: true)
        }
    }
    
    /// 格式化日志信息
    private static func formatMessage(_ params: Any?) -> String {
        if let str = params as? String {
            return str
        } else if let params = params as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: params, options:.prettyPrinted),
                  let jsonString = String(data: jsonData, encoding:.utf8) {
            return jsonString
        } else if let params = params as? [Any] {
            return "\(params)" // 支持数组类型
        } else if let params = params {
            return "\(params)"
        }
        return ""
    }
}
