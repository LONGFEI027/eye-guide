//
//  RGCxrAESUtils.swift
//  RGCxrKit
//
//  Created by Ginger on 2025/11/3.
//

import Foundation
import CommonCrypto

internal class RGCxrAESUtils: NSObject {
    
    /// 解密 .lc 鉴权文件
    /// - Parameters:
    ///   - content: 加密的文件内容（Data格式）
    ///   - key: 处理后的Client Secret（32位，无连字符）
    /// - Returns: 解密后的JSON字符串
    static func decrypt(content: Data, key: String) -> String? {
        let processedKey = key.replacingOccurrences(of: "-", with: "")
        // 将密钥字符串编码为UTF-8字节
        guard let keyData = processedKey.data(using: .utf8) else {
            return nil
        }
        
        // 确保密钥长度至少为32字节（AES-256需要32字节）
        guard keyData.count >= 32 else {
            return nil
        }
        
        // 使用key的前16字节作为IV（需要转换为Data）
        let iv = Data(keyData.prefix(16))
        
        // 使用AES-256密钥（前32字节，需要转换为Data）
        let aesKey = Data(keyData.prefix(32))
        
        // 执行AES CBC解密（CCCrypt会自动处理PKCS7填充）
        guard let decryptedData = performAESDecrypt(ciphertext: content, key: aesKey, iv: iv) else {
            return nil
        }
        
        // 解码为UTF-8字符串
        return String(data: decryptedData, encoding: .utf8)
    }
    
    /// 执行AES CBC解密
    private static func performAESDecrypt(ciphertext: Data, key: Data, iv: Data) -> Data? {
        // 确保密钥长度正确
        guard key.count == kCCKeySizeAES256 else {
            return nil
        }
        
        // 确保IV长度正确（16字节）
        guard iv.count == kCCBlockSizeAES128 else {
            return nil
        }
        
        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0
        
        let status = buffer.withUnsafeMutableBytes { bufferBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            kCCKeySizeAES256,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            bufferBytes.baseAddress,
                            bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        
        guard status == kCCSuccess else {
            return nil
        }
        
        // 返回实际解密的数据长度（转换为Data）
        return Data(buffer.prefix(numBytesDecrypted))
    }
    
}
