//
//  RGCore.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/4/21.
//

import Foundation

public struct RGApplication {
    /// 沙盒 Document 地址
    public static var documentPath: String { NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! }
    /// 沙盒 Document URL
    public static var documentUrl: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last! }
    /// 沙盒 Cache 地址
    public static var cachePath: String { NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first! }
    /// 沙盒 Cache URL
    public static var cacheUrl: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).last! }
    /// 沙盒 Library 地址
    public static var libraryPath: String { NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first! }
    /// 沙盒 Library URL
    public static var libraryUrl: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).last! }
    /// Application's Bundle Name (show in SpringBoard).
    public static var bundleName: String { Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "" }
    public static var displayName: String { Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "" }
    /// Application's Bundle ID.  e.g. "com.xuetian.cn"
    public static var bundleId: String { Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "" }
    /// Application's Version.  e.g. "1.0.0"
    public static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String  ?? "" }
    /// Application's Build number. e.g. "123"
    public static var buildVersion: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
}

