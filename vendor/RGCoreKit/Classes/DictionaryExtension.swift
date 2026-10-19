//
//  DictionaryExtension.swift
//  Pods
//
//  Created by Ginger on 2025/2/25.
//


//
//  Created by Tom Baranes on 24/04/16.
//  Copyright © 2016 Tom Baranes. All rights reserved.
//

import Foundation

// MARK: - Helpers

extension Dictionary {

    /// Check if the Dictionary contains a specified key
    /// - Parameter key: The key to check.
    /// - Returns: true if the key is in the dictionary, otherwise false.
    public func has(key: Key) -> Bool {
        index(forKey: key) != nil
    }

}

// MARK: - Value Getters

extension Dictionary where Key == String {
    
    /// 根据键名获取字符串值
    /// - Parameter name: 键名
    /// - Returns: 字符串值，获取不到返回 nil
    public func stringValue(of name: String) -> String? {
        if let value = self[name] {
            if let stringValue = value as? String {
                return stringValue
            }
            // 尝试转换其他类型为字符串
            if let number = value as? NSNumber {
                return number.stringValue
            }
            return "\(value)"
        }
        return nil
    }
    
    /// 根据键名获取整数值
    /// - Parameter name: 键名
    /// - Returns: 整数值，获取不到返回 nil
    public func intValue(of name: String) -> Int? {
        if let value = self[name] {
            if let intValue = value as? Int {
                return intValue
            }
            // 尝试从其他类型转换
            if let number = value as? NSNumber {
                return number.intValue
            }
            if let stringValue = value as? String {
                return Int(stringValue)
            }
        }
        return nil
    }
    
    /// 根据键名获取布尔值
    /// - Parameter name: 键名
    /// - Returns: 布尔值，获取不到返回 false
    public func boolValue(of name: String) -> Bool {
        if let value = self[name] {
            if let boolValue = value as? Bool {
                return boolValue
            }
            // 尝试从其他类型转换
            if let number = value as? NSNumber {
                return number.boolValue
            }
            if let stringValue = value as? String {
                let lowercased = stringValue.lowercased()
                return lowercased == "true" || lowercased == "1" || lowercased == "yes"
            }
            if let intValue = value as? Int {
                return intValue != 0
            }
        }
        return false
    }
    
}

// MARK: - JSON

extension Dictionary {
    
    /// Data from dictionary
    /// - Parameter options: `JSONSerialization.WritingOptions`
    /// - Returns: `Data?`
    public func toJsonData(options: JSONSerialization.WritingOptions = []) -> Data? {
        if let jsonData = try? JSONSerialization.data(withJSONObject: self, options: options) {
            return jsonData
        }
        return nil
    }
    
    /// 字典转json字符串
    ///
    /// - Returns: 字典的字符串
    /// 
    public func toJsonString(prettyPrint: Bool = false) -> String? {
        if JSONSerialization.isValidJSONObject(self) {
            do {
                let jsonData: Data
                if prettyPrint {
                    jsonData = try JSONSerialization.data(withJSONObject: self, options: [.prettyPrinted])
                } else {
                    jsonData = try JSONSerialization.data(withJSONObject: self, options: [])
                }
                return String(data: jsonData, encoding: .utf8)
            } catch let error {
                return nil
            }
        } else {
            return nil
        }
    }
}

// MARK: - Transform

extension Dictionary {

    /// Add each Dictionary's unique key-value in this one.
    /// - Parameter values: all the dictionaries that will be added to this one.
    /// - Returns: A Dictionary containing all the keys-values of this Dictionary
    ///            plus all the unique ones from the others array.
    public func union(values: Dictionary...) -> Dictionary {
        var result = self
        values.forEach { dictionary in
            dictionary.forEach { key, value in
                result[key] = value
            }
        }
        return result
    }

    /// Merge all the dictionaries into this one.
    /// - Parameter dictionaries: all the dictionaries to merge into this one.
    public mutating func merge<K, V>(with dictionaries: [K: V]...) {
        dictionaries.forEach {
            for (key, value) in $0 {
                guard let value = value as? Value, let key = key as? Key else {
                    continue
                }

                self[key] = value
            }
        }
    }

}

// MARK: - Equatable Transform

extension Dictionary where Value: Equatable {

    /// Calculate all the differences between this Dictionary and others.
    /// - Parameter dictionaries: All the dictionaries that will be compared with the current one.
    /// - Returns: A Dictionary containing all the difference between this one and the others.
    public func difference(with dictionaries: [Key: Value]...) -> [Key: Value] {
        var result = self
        dictionaries.forEach {
            for (key, value) in $0 {
                if result.has(key: key) && result[key] == value {
                    result[key] = nil
                }
            }
        }
        return result
    }

}

extension Encodable {
    public func toDictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let dictionary = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "toDictionary", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to convert to dictionary"])
        }
        return dictionary
    }
}
