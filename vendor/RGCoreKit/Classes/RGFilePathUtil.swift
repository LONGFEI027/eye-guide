//
//  RGFilePathUtil.swift
//  RGCoreKit
//
//  Created by Ginger on 2025/3/9.
//

import UIKit

public class RGFilePathUtil: NSObject {
    
    public static func getDocumentPath() -> String? {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        return paths[safe: 0]
    }
    
    public static func getDirectoryForDocuments(dir: String) -> String? {
        if let document = getDocumentPath() {
            let dirPath = document + "/" + dir
            var isDir: ObjCBool = false
            let isCreated = FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir)
            if !isCreated || !isDir.boolValue {
                try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            }
            return dirPath
        }
        return nil
    }
    
    public static func getAbsolutePath(withFileRelativePath fileRelativePath: String?) -> String? {
        guard let fileRelativePath = fileRelativePath, !fileRelativePath.isEmpty, let rootPath = getDocumentPath() else {
            return nil
        }
        return (rootPath as NSString).appendingPathComponent(fileRelativePath)
    }

    public static func getRelativePath(withFileAbsolutePath fileAbsolutePath: String?) -> String? {
        guard let fileAbsolutePath = fileAbsolutePath, !fileAbsolutePath.isEmpty, let rootPath = getDocumentPath() else {
            return nil
        }
        return fileAbsolutePath.replacingOccurrences(of: rootPath, with: "")
    }

}
