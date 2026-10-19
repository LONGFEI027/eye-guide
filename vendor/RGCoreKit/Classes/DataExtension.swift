//
//  DataExtension.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/4/10.
//

import Foundation



extension Data {
    
    /// 内容是否大于 n kb
    /// - Parameter kb: 单位kb
    /// - Returns: 对比结果
    public func isLargerThan(kilobytes kb: Int) -> Bool {
        return self.count > kb * 1024
    }
    
    public func convertTo<T: Any>() -> T? {
        do {
            let jsonObject = try JSONSerialization.jsonObject(
                with: self,
                options: []
            ) as? T
            return jsonObject
        } catch {
            return nil
        }
    }
}
