//
//  RGCxrKit+Keychain.swift
//  RGCxrKit
//
//  Created by Ginger on 2025/8/16.
//

import Foundation
import RGCoreKit

fileprivate let cxr_serviceRecord = "cxr_serviceRecord"
fileprivate let cxr_macAddress = "cxr_macAddress"
fileprivate let cxr_glassesMacAddress = "cxr_glassesMacAddress"
fileprivate let cxr_serviceRecordMap = "cxr_serviceRecordMap" // 新格式：按 serialNumber 存储的字典
fileprivate let cxr_glassesMacAddressMap = "cxr_glassesMacAddressMap" // 新格式：按 serialNumber 存储的字典
fileprivate let cxr_accountMap = "cxr_accountMap" // 新格式：按 serialNumber 存储的字典
fileprivate let cxr_blacklist = "cxr_blacklist"
fileprivate let cxr_account = "cxr_account"

extension RGCxrKitImp {
    
    /// 获取 ServiceRecord，根据 serialNumber 查找
    /// - Parameter serialNumber: 设备序列号，如果为 nil 则尝试从旧格式迁移
    /// - Returns: ServiceRecord 字符串
    internal func getServiceRecord(for serialNumber: String?) -> String? {
        RGLog.api(serialNumber)
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            // 如果没有 serialNumber，尝试从旧格式读取（兼容性处理）
            return getLegacyServiceRecord()
        }
        
        // 从新格式读取（字典格式）
        var record: String? = nil
        if let recordMap = UserDefaults.standard.dictionary(forKey: cxr_serviceRecordMap) as? [String: String] {
            record = recordMap[serialNumber]
            RGLog.info(recordMap)
        }
        // 如果新格式还是找不到，尝试从旧格式迁移
        if record.isNilOrEmpty, !isNewPairing {
            record = migrateLegacyServiceRecord(to: serialNumber)
        }
        
        return record
    }
    
    /// 设置 ServiceRecord，根据 serialNumber 存储
    /// - Parameters:
    ///   - record: ServiceRecord 字符串
    ///   - serialNumber: 设备序列号
    internal func setServiceRecord(_ record: String, for serialNumber: String?) {
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            // 如果没有 serialNumber，使用旧格式存储（兼容性处理）
            RGLog.api(record)
            UserDefaults.standard.set(record, forKey: cxr_serviceRecord)
            KeychainSwift().set(record, forKey: cxr_serviceRecord)
            return
        }
        
        RGLog.api(["record": record, "serialNumber": serialNumber])
        
        // 读取现有的字典
        var recordMap: [String: String] = [:]
        if let existingMap = UserDefaults.standard.dictionary(forKey: cxr_serviceRecordMap) as? [String: String] {
            recordMap = existingMap
            RGLog.info(recordMap)
        }
        
        // 更新字典
        recordMap[serialNumber] = record
        
        // 保存到 UserDefaults
        UserDefaults.standard.set(recordMap, forKey: cxr_serviceRecordMap)
    }
    
    /// 从旧格式读取 ServiceRecord（兼容性处理）
    private func getLegacyServiceRecord() -> String? {
        RGLog.api()
        var record = UserDefaults.standard.string(forKey: cxr_serviceRecord)
        if record.isNilOrEmpty {
            record = KeychainSwift().get(cxr_serviceRecord)
        }
        return record
    }
    
    /// 将旧格式的 ServiceRecord 迁移到新格式
    /// - Parameter serialNumber: 目标 serialNumber
    /// - Returns: 迁移的 ServiceRecord，如果不存在则返回 nil
    private func migrateLegacyServiceRecord(to serialNumber: String) -> String? {
        RGLog.api(serialNumber)
        guard let legacyRecord = getLegacyServiceRecord(), !legacyRecord.isEmpty else {
            return nil
        }
        
        // 迁移到新格式
        setServiceRecord(legacyRecord, for: serialNumber)
        RGLog.info("Migrated legacy ServiceRecord to serialNumber: \(serialNumber)")
        return legacyRecord
    }
    
    internal func getMacAddress() -> String? {
        if let innerMacAddress = innerMacAddress,
           !innerMacAddress.isEmpty {
            return innerMacAddress
        }
        var address = UserDefaults.standard.string(forKey: cxr_macAddress)
        if address.isNilOrEmpty {
            address = KeychainSwift().get(cxr_macAddress)
        }
        innerMacAddress = address
        return address
    }

    internal func setMacAddress(_ address: String) {
        RGLog.api(address)
        innerMacAddress = address
        UserDefaults.standard.set(address, forKey: cxr_macAddress)
    }
    
    internal func clearKeychain() {
        RGLog.api()
        // 清除旧格式
        KeychainSwift().set("", forKey: cxr_serviceRecord)
        KeychainSwift().set("", forKey: cxr_macAddress)
        UserDefaults.standard.set("", forKey: cxr_serviceRecord)
        UserDefaults.standard.set("", forKey: cxr_macAddress)
        UserDefaults.standard.set("", forKey: cxr_account)
        // 清除新格式
        KeychainSwift().set("", forKey: cxr_serviceRecordMap)
        KeychainSwift().set("", forKey: cxr_glassesMacAddressMap)
        UserDefaults.standard.set([:], forKey: cxr_serviceRecordMap)
        UserDefaults.standard.set([:], forKey: cxr_glassesMacAddressMap)
        UserDefaults.standard.set([:], forKey: cxr_accountMap)
        innerMacAddress = nil
        innerAccount = nil
    }
    
    /// 清除指定设备的 ServiceRecord 和 GlassesMacAddress
    /// - Parameter serialNumber: 设备序列号
    internal func clearKeychain(for serialNumber: String?) {
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            return
        }
        RGLog.api(serialNumber)
        
        // 清除 ServiceRecord
        var recordMap: [String: String] = [:]
        if let existingMap = UserDefaults.standard.dictionary(forKey: cxr_serviceRecordMap) as? [String: String] {
            recordMap = existingMap
        }
        recordMap.removeValue(forKey: serialNumber)
        UserDefaults.standard.set(recordMap, forKey: cxr_serviceRecordMap)
        
        // 清除 GlassesMacAddress
        var addressMap: [String: String] = [:]
        if let existingMap = UserDefaults.standard.dictionary(forKey: cxr_glassesMacAddressMap) as? [String: String] {
            addressMap = existingMap
        }
        addressMap.removeValue(forKey: serialNumber)
        UserDefaults.standard.set(addressMap, forKey: cxr_glassesMacAddressMap)
        
        // 清除 Account
        var accountMap: [String: String] = [:]
        if let existingMap = UserDefaults.standard.dictionary(forKey: cxr_accountMap) as? [String: String] {
            accountMap = existingMap
        }
        accountMap.removeValue(forKey: serialNumber)
        UserDefaults.standard.set(accountMap, forKey: cxr_accountMap)
        
        // 如果当前设备是清除的设备，清空内存缓存
        if self.serialNumber == serialNumber {
            glassesMacAddress = nil
            innerAccount = nil
        }
    }
    
    internal func clearMacAddress() {
        RGLog.api()
        KeychainSwift().set("", forKey: cxr_macAddress)
        UserDefaults.standard.set("", forKey: cxr_macAddress)
        innerMacAddress = nil
    }
    
    // MARK: - Blacklist Management
    
    /// 获取黑名单列表
    internal func getBlacklist() -> [String] {
        if let innerBlacklist = innerBlacklist {
            return innerBlacklist
        }
        var blacklist: [String] = []
        
        // 先从 UserDefaults 读取
        if let userDefaultsList = UserDefaults.standard.array(forKey: cxr_blacklist) as? [String] {
            blacklist = userDefaultsList
        }
        
        innerBlacklist = blacklist
        return blacklist
    }
    
    /// 添加黑名单项
    internal func addToBlacklist(_ item: String) {
        guard !item.isEmpty else { return }
        RGLog.api(item)
        
        var blacklist = getBlacklist()
        if !blacklist.contains(item) {
            blacklist.append(item)
            saveBlacklist(blacklist)
        }
    }
    
    /// 移除黑名单项
    internal func removeFromBlacklist(_ item: String) {
        guard !item.isEmpty else { return }
        RGLog.api(item)
        
        var blacklist = getBlacklist()
        if let index = blacklist.firstIndex(of: item) {
            blacklist.remove(at: index)
            saveBlacklist(blacklist)
        }
    }
    
    /// 清除整个黑名单
    internal func clearBlacklist() {
        RGLog.api()
        innerBlacklist = nil
        UserDefaults.standard.set([], forKey: cxr_blacklist)
    }
    
    /// 保存黑名单到存储
    private func saveBlacklist(_ blacklist: [String]) {
        innerBlacklist = blacklist
        UserDefaults.standard.set(blacklist, forKey: cxr_blacklist)
    }
    
    /// 设置 GlassesMacAddress，根据 serialNumber 存储
    /// - Parameters:
    ///   - macAddress: MAC 地址
    ///   - serialNumber: 设备序列号
    internal func setGlassesMacAddress(_ macAddress: String?, for serialNumber: String?) {
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            // 如果没有 serialNumber，使用旧格式存储（兼容性处理）
            RGLog.api(macAddress)
            glassesMacAddress = macAddress
            UserDefaults.standard.set(macAddress, forKey: cxr_glassesMacAddress)
            return
        }
        
        RGLog.api(["macAddress": macAddress ?? "", "serialNumber": serialNumber])
        glassesMacAddress = macAddress
        
        // 读取现有的字典
        var addressMap: [String: String] = [:]
        if let existingMap = UserDefaults.standard.dictionary(forKey: cxr_glassesMacAddressMap) as? [String: String] {
            addressMap = existingMap
        }
        
        // 如果 UserDefaults 没有，尝试从 Keychain 读取
        if addressMap.isEmpty {
            if let keychainMap = KeychainSwift().get(cxr_glassesMacAddressMap),
               let data = keychainMap.data(using: .utf8),
               let existingMap = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                addressMap = existingMap
            }
        }
        
        // 更新字典
        if let macAddress = macAddress {
            addressMap[serialNumber] = macAddress
        } else {
            addressMap.removeValue(forKey: serialNumber)
        }
        
        // 保存到 UserDefaults
        UserDefaults.standard.set(addressMap, forKey: cxr_glassesMacAddressMap)
    }
    
    /// 获取 GlassesMacAddress，根据 serialNumber 查找
    /// - Parameter serialNumber: 设备序列号，如果为 nil 则尝试从旧格式迁移
    /// - Returns: MAC 地址字符串
    internal func getGlassesMacAddress(for serialNumber: String?) -> String? {
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            // 如果没有 serialNumber，尝试从旧格式读取（兼容性处理）
            return getLegacyGlassesMacAddress()
        }
        
        // 先从内存缓存读取（仅当 serialNumber 匹配时使用缓存）
        if let glassesMacAddress = glassesMacAddress,
           !glassesMacAddress.isEmpty,
           self.serialNumber == serialNumber {
            return glassesMacAddress
        }
        
        // 从新格式读取（字典格式）
        var address: String? = nil
        if let addressMap = UserDefaults.standard.dictionary(forKey: cxr_glassesMacAddressMap) as? [String: String] {
            address = addressMap[serialNumber]
        }
        
        // 如果新格式找不到，尝试从 Keychain 读取
        if address.isNilOrEmpty {
            if let keychainMap = KeychainSwift().get(cxr_glassesMacAddressMap),
               let data = keychainMap.data(using: .utf8),
               let addressMap = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                address = addressMap[serialNumber]
            }
        }
        
        // 如果新格式还是找不到，尝试从旧格式迁移
        if address.isNilOrEmpty {
            address = migrateLegacyGlassesMacAddress(to: serialNumber)
        }
        
        glassesMacAddress = address
        return address
    }
    
    /// 从旧格式读取 GlassesMacAddress（兼容性处理）
    private func getLegacyGlassesMacAddress() -> String? {
        return UserDefaults.standard.string(forKey: cxr_glassesMacAddress)
    }
    
    /// 将旧格式的 GlassesMacAddress 迁移到新格式
    /// - Parameter serialNumber: 目标 serialNumber
    /// - Returns: 迁移的 MAC 地址，如果不存在则返回 nil
    private func migrateLegacyGlassesMacAddress(to serialNumber: String) -> String? {
        guard let legacyAddress = getLegacyGlassesMacAddress(), !legacyAddress.isEmpty else {
            return nil
        }
        
        // 迁移到新格式
        setGlassesMacAddress(legacyAddress, for: serialNumber)
        RGLog.info("Migrated legacy GlassesMacAddress to serialNumber: \(serialNumber)")
        return legacyAddress
    }
    
    /// 设置 Account，根据 serialNumber 存储
    /// - Parameters:
    ///   - account: Account 字符串
    ///   - serialNumber: 设备序列号
    internal func setAccount(_ account: String?, for serialNumber: String?) {
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            // 如果没有 serialNumber，使用旧格式存储（兼容性处理）
            RGLog.api(account)
            innerAccount = account
            UserDefaults.standard.set(account, forKey: cxr_account)
            return
        }
        
        RGLog.api(["account": account ?? "", "serialNumber": serialNumber])
        // 如果当前设备是目标设备，更新内存缓存
        if self.serialNumber == serialNumber {
            innerAccount = account
        }
        
        // 读取现有的字典
        var accountMap: [String: String] = [:]
        if let existingMap = UserDefaults.standard.dictionary(forKey: cxr_accountMap) as? [String: String] {
            accountMap = existingMap
        }
        
        // 更新字典
        if let account = account {
            accountMap[serialNumber] = account
        } else {
            accountMap.removeValue(forKey: serialNumber)
        }
        
        // 保存到 UserDefaults
        UserDefaults.standard.set(accountMap, forKey: cxr_accountMap)
    }
    
    /// 获取 Account，根据 serialNumber 查找
    /// - Parameter serialNumber: 设备序列号，如果为 nil 则尝试从旧格式迁移
    /// - Returns: Account 字符串
    internal func getAccount(for serialNumber: String?) -> String? {
        guard let serialNumber = serialNumber, !serialNumber.isEmpty else {
            // 如果没有 serialNumber，尝试从旧格式读取（兼容性处理）
            return getLegacyAccount()
        }
        
        // 先从内存缓存读取（仅当 serialNumber 匹配时使用缓存）
        if let account = innerAccount,
           !account.isEmpty,
           self.serialNumber == serialNumber {
            return account
        }
        
        // 从新格式读取（字典格式）
        var account: String? = nil
        if let accountMap = UserDefaults.standard.dictionary(forKey: cxr_accountMap) as? [String: String] {
            account = accountMap[serialNumber]
        }
        
        // 如果新格式还是找不到，尝试从旧格式迁移
        if account.isNilOrEmpty {
            account = migrateLegacyAccount(to: serialNumber)
        }
        
        // 如果当前设备是目标设备，更新内存缓存
        if self.serialNumber == serialNumber {
            innerAccount = account
        }
        
        return account
    }
    
    /// 从旧格式读取 Account（兼容性处理）
    private func getLegacyAccount() -> String? {
        if let account = innerAccount,
           !account.isEmpty {
            return account
        }
        innerAccount = UserDefaults.standard.string(forKey: cxr_account)
        return innerAccount
    }
    
    /// 将旧格式的 Account 迁移到新格式
    /// - Parameter serialNumber: 目标 serialNumber
    /// - Returns: 迁移的 Account，如果不存在则返回 nil
    private func migrateLegacyAccount(to serialNumber: String) -> String? {
        guard let legacyAccount = getLegacyAccount(), !legacyAccount.isEmpty else {
            return nil
        }
        
        // 迁移到新格式
        setAccount(legacyAccount, for: serialNumber)
        RGLog.info("Migrated legacy Account to serialNumber: \(serialNumber)")
        return legacyAccount
    }
    
    /// 兼容旧接口：设置 Account（使用当前 serialNumber）
    internal func setAccount(_ account: String?) {
        setAccount(account, for: serialNumber)
    }
    
    /// 兼容旧接口：获取 Account（使用当前 serialNumber）
    internal func getAccount() -> String? {
        return getAccount(for: serialNumber)
    }
}
