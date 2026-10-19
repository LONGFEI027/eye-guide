//
//  RGIDs.swift
//  RGUIKit
//
//  Created by Ginger on 2025/2/27.
//

import UIKit

let deviceIdKey = "RGDeviceIdKey"

public class RGIDs: NSObject {
    
    
    /// 设备唯一ID
    public class func getDeviceId() -> String {
        if let id = UserDefaults.standard.object(forKey: deviceIdKey) as? String {
            return id
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        UserDefaults.standard.synchronize()
        return id
    }
    
    static var progressId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static var progressLongId = Int(Date().timeIntervalSince1970)
    
    /// 单次进程唯一ID
    public class func getProgressId() -> String {
        progressId
    }
    
    /// 单次进程唯一ID
    public class func getLongProgressId() -> Int {
        progressLongId
    }


}
