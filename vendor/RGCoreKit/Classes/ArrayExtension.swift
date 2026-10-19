//
//  ArrayExtension.swift
//  Pods
//
//  Created by Ginger on 2025/2/21.
//

import Foundation


extension Array {
    // 数组安全访问，避免越界问题
    // 示例 numbers[safe: 2]
    public subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
    
    /// 将数组转换为JSON字符串
    /// - Parameter prettyPrinted: 是否格式化输出（带缩进和换行）
    /// - Returns: 转换后的JSON字符串，失败则返回nil
    public func toString(prettyPrinted: Bool = false) -> String? {
        // 检查数组元素是否可被JSON序列化
        guard JSONSerialization.isValidJSONObject(self) else {
            print("数组包含无法JSON序列化的元素")
            return nil
        }
        
        do {
            // 设置序列化选项：是否格式化输出
            let options: JSONSerialization.WritingOptions = prettyPrinted ? .prettyPrinted : []
            
            // 转换为JSON数据
            let jsonData = try JSONSerialization.data(withJSONObject: self, options: options)
            
            // 转换为UTF-8编码的字符串
            return String(data: jsonData, encoding: .utf8)
        } catch {
            print("数组转JSON失败：\(error.localizedDescription)")
            return nil
        }
    }
}

extension Array where Element: Equatable {
    public mutating func remove(first element: Element) {
        if let index = self.firstIndex(of: element) {
            self.remove(at: index)
        }
    }
}


extension Array where Element: Hashable {
    /// 判断两个数组元素是否相同（不考虑顺序，考虑重复元素）
    public func elementsEqualIgnoringOrder(_ other: [Element]) -> Bool {
        guard self.count == other.count else { return false }
        return NSCountedSet(array: self) == NSCountedSet(array: other)
    }
    
    /// 判断两个数组元素是否相同（不考虑顺序，不考虑重复元素）
    public func elementsEqualIgnoringOrderAndDuplicates(_ other: [Element]) -> Bool {
        return Set(self) == Set(other)
    }
}
