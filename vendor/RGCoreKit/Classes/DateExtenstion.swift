//
//  DateExtenstion.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/6/6.
//

import Foundation



extension Date {
    // 获取日期的开始（去掉时间部分）
    var startOfDay: Date {
        return Calendar.current.startOfDay(for: self)
    }
    // 是否早于某天
    public func isBeforeDay(_ date: Date) -> Bool {
        return self.startOfDay < date.startOfDay
    }
    // 是否晚于某天
    public func isAfterDay(_ date: Date) -> Bool {
        return self.startOfDay > date.startOfDay
    }
    /// 获取当前时间的字符串表示
    /// - Parameter format: 时间格式，默认为 "yyyy-MM-dd HH:mm:ss"
    /// - Returns: 格式化后的时间字符串
    public func formattedString(format: String = "yyyy-MM-dd HH:mm:ss") -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: self)
    }
    
    public func time(type: FormatterType) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = type.formatter()
        return formatter.string(from: self)
    }
    
    /// 判断是否同一天
    public func isSameDay(with date: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.isDate(self, inSameDayAs: date)
    }
    
    /// 获取 星期几 （1: 周日 2: 周一 ... 7: 周六）
    public func weekDay(with names: [String]) -> String {
        let calendar = Calendar.current
        let weekdayComponent = calendar.component(.weekday, from: self)
        return names[weekdayComponent - 1]
    }
    
    // 获取 n 年前的日期（保持时分秒）
    public func yearsAgo(_ years: Int) -> Date {
        Calendar.current.date(byAdding: .year, value: -years, to: self) ?? self
    }
    // 获取 n 年后的日期（保持时分秒）
    func yearsAfter(_ years: Int) -> Date {
        Calendar.current.date(byAdding: .year, value: years, to: self) ?? self
    }
}

extension Date {
    
    // 只到分钟的时间戳
    public var timeIntervalSince1970ToMinute: TimeInterval {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        if let date = calendar.date(from: components) {
            return date.timeIntervalSince1970
        }
        return (self.timeIntervalSince1970 / 60).rounded(.down) * 60
    }
}

