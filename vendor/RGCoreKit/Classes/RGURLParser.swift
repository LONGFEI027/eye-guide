//
//  RGURLParser.swift
//  RGCoreKit
//
//  Created by Topredator XL on 2025/12/18.
//

import Foundation


public struct RGURLResult {
    public var url: URL
    public var scheme: String? {
        url.scheme
    }
    public var host: String? {
        url.host
    }
    public var path: String? {
        url.path()
    }
    public var params: [String: Any]?
    
    public func value(with name: String) -> Any? {
        params?[name]
    }
}


public class RGURL {
    public static func parseURL(_ url: URL) -> RGURLResult {
        var params: [String: Any] = [:]
        
        // 解析标准查询参数 (?key=value)
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let queryItems = components.queryItems {
            for item in queryItems {
                params[item.name] = item.value
            }
        }
        
        // 解析 path 中的参数 (/key=value 或 /key=value/key2=value2)
        let path = url.path
        if !path.isEmpty {
            let pathComponents = path.split(separator: "/")
            for component in pathComponents {
                let keyValue = component.split(separator: "=", maxSplits: 1)
                if keyValue.count == 2 {
                    let key = String(keyValue[0])
                    let value = String(keyValue[1])
                    params[key] = value
                }
            }
        }
        return RGURLResult(url: url, params: params)
    }
    
    // 解析 URL 字符串
    public static func parseURLString(_ urlString: String) -> RGURLResult? {
        guard let url = URL(string: urlString) else { return nil }
        return parseURL(url)
    }
    
    public static func open(urlString url: String, isMainQueue: Bool = true) {
        openUrl(URL(string: url), isMainQueue: isMainQueue)
    }
    /// 打开链接
    public static func openUrl(_ url: URL?, isMainQueue: Bool = false) {
        guard let url = url else {
            print("Error: Invalid url.")
            return
        }
        guard UIApplication.shared.canOpenURL(url) else {
            return
        }
        if isMainQueue {
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { flag in
                    if flag {
                        print("Open \(url) successfully.")
                    } else {
                        print("Failed to open \(url).")
                    }
                }
            }
        } else {
            UIApplication.shared.open(url) { flag in
                if flag {
                    print("Open \(url) successfully.")
                } else {
                    print("Failed to open \(url).")
                }
            }
        }
        
    }
    
}
