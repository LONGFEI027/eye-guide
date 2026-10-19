//
//  RGCxrKit.swift
//  RGCxrKit
//
//  Created by Ginger on 2025/9/24.
//

import Foundation
import CoreBluetooth
import ExternalAccessory
@_implementationOnly import RGCxrKit_Private
import Combine


public class RGCxrKit: NSObject {

    /// 单例方法
    public static let shared = RGCxrKit()

    private let cxrImp = RGCxrKitImp()

    /// 在后台时收到蓝牙消息可以短暂处理上层业务
    public var backgroundTimerPublisher: AnyPublisher<TimeInterval, Never> {
        cxrImp.backgroundTimerSubject.share().eraseToAnyPublisher()
    }

    /// 连接状态
    public var connectionStatusPublisher: AnyPublisher<Bool, Never> {
        cxrImp.connectionStatusSubject.share().eraseToAnyPublisher()
    }

    /// 原始数据 Publisher（从设备读取的原始数据，在协议解析之前）
    public var rawDataPublisher: AnyPublisher<Data, Never> {
        cxrImp.rawDataSubject.share().eraseToAnyPublisher()
    }

    /// 音频流开始 Publisher
    public var startAudioStreamPublisher: AnyPublisher<(codec: Int32, type: String, channels: UInt32), Never> {
        cxrImp.startAudioStreamSubject.share().eraseToAnyPublisher()
    }

    /// 数据流
    public var streamPublisher: AnyPublisher<RGCxrStreamResponse, Never> {
        cxrImp.streamSubject.share().eraseToAnyPublisher()
    }

    /// 音频数据 Publisher
    public var audioStreamPublisher: AnyPublisher<(data: Data, timestamp: UInt64), Never> {
        cxrImp.audioStreamSubject.share().eraseToAnyPublisher()
    }
    
    /// 音频结束
    public var audioStreamFinishPublisher: AnyPublisher<Void, Never> {
        cxrImp.audioStreamFinishSubject.share().eraseToAnyPublisher()
    }

    /// 消息通知 Publisher
    public var dataNotifyPublisher: AnyPublisher<RGCxrDataResponse, Never> {
        cxrImp.dataNotifySubject.share().eraseToAnyPublisher()
    }

    /// 账号校验回调代理
    public weak var accountDelegate: RGCxrAccountDelegate? {
        set {
            cxrImp.accountDelegate = newValue
        }
        get {
            cxrImp.accountDelegate
        }
    }

    /// 蓝牙是否开启
    public var centralManagerState: CBManagerState {
        cxrImp.centralManager?.state ?? .poweredOff
    }

    /// 已发现的设备
    public var foundPeripherals: [RGCxrPeripheral] {
        cxrImp.foundPeripherals
    }

    /// 已经连接的设备
    public var connectedPeripheral: RGCxrPeripheral? {
        cxrImp.connectedPeripheral
    }

    /// 是否是MFI设备
    public var isMFI: Bool {
        cxrImp.isMFI
    }

    /// 眼镜的mac地址
    public var glassesMacAddress: String? {
        cxrImp.getGlassesMacAddress(for: cxrImp.serialNumber)
    }

    /// 是否海外版本，protocolString不一样
    public var isGlobal: Bool {
        set {
            cxrImp.isGlobal = newValue
        }
        get {
            cxrImp.isGlobal
        }
    }

    /// 当前连接的MFI设备
    public var currentAccessory: EAAccessory? {
        get {
            cxrImp.currentAccessory
        }
    }

    /// 当前蓝牙连接状态
    public var connectionStatus: RGCxrConnectionStatus {
        get {
            cxrImp.innerConnectionStatus
        }
    }

    /// 当前去连接的或者已经连接的设备序列号
    public var serialNumber: String? {
        get {
            cxrImp.serialNumber
        }
    }

    /// 初始化SDK
    public func setup() {
        cxrImp.setup()
    }

    /// 开始蓝牙设备发现
    public func startScan() {
        cxrImp.startScan()
    }

    /// 关闭蓝牙设备发现
    public func stopScan() {
        cxrImp.stopScan()
    }

    /// 暂停重连
    public func pauseReconnecting() {
        cxrImp.pauseReconnecting()
    }

    /// 恢复重连
    public func resumeReconnecting() {
        cxrImp.resumeReconnecting()
    }

    /// 清空所有缓存
    public func clearCache() {
        cxrImp.clearCache()
    }

    /// 配对
    /// - Parameters:
    ///   - serialNumber: 要连接的设备的序列号
    ///   - new: 是否是重新配对，回连传false
    public func connect(to serialNumber: String, new: Bool) {
        cxrImp.connect(to: serialNumber, new: new)
    }

    /// 从解密后的内容中解析 snList 数组
    /// - Parameter content: 解密后的字符串，格式如：{client_id=chengqi_test_001, snList=[2001092517000208]}
    /// - Returns: snList 中的字符串数组
    private func parseSnList(from content: String) -> [String] {
        // 查找 snList=[...] 的模式
        let pattern = "snList=\\[([^\\]]+)\\]"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let nsRange = NSRange(location: 0, length: content.utf16.count)
        guard let match = regex.firstMatch(in: content, options: [], range: nsRange),
              match.numberOfRanges > 1 else {
            return []
        }

        // 提取括号内的内容
        let range = Range(match.range(at: 1), in: content)
        guard let contentRange = range else {
            return []
        }

        let snListContent = String(content[contentRange])

        // 分割逗号，去除空格，过滤空字符串
        return snListContent
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 配对
    /// - Parameters:
    ///   - serialNumber: 要连接的设备的序列号
    ///   - new: 是否是重新配对，回连传false
    ///   - snEncryptContent: SN加密内容
    ///   - clientSecret: 开发者Client Secret
    public func connect(to serialNumber: String, new: Bool, snEncryptContent: Data, clientSecret: String) {
        if let content = RGCxrAESUtils.decrypt(content: snEncryptContent, key: clientSecret) {
            let snList = parseSnList(from: content)
            if snList.contains(serialNumber) {
                cxrImp.connect(to: serialNumber, new: new)
                return
            }
        }
        cxrImp.connectionDelegates.forEachWeakObject { (delegate: NSObjectProtocol?) in
            if let delegate = delegate as? RGCxrConnectionDelegate {
                DispatchQueue.main.async {
                    delegate.onConnectionError(.authFailed)
                }
            }
        }
    }

    /// 取消配对，断开蓝牙连接
    /// - Parameter callback: 断开结果回调
    public func cancelConnect(_ callback: (() -> Void)?) {
        cxrImp.cancelConnect(callback)
    }

    /// 取消配对，断开蓝牙连接并清除缓存的mac地址
    /// - Parameter callback: 断开结果回调
    public func cancelConnectAndClearCache(_ callback: (() -> Void)?) {
        cxrImp.clearMacAddress()
        cxrImp.cancelConnect(callback)
    }

    /// 发送命令到蓝牙设备，WARNING: 弃用
    /// - Parameters:
    ///   - cmd: 指令
    ///   - data: 数据
    ///   - onResponse: 设备回包
    public func sendData(cmd: String, subCmd: String? = nil, data: Any?, onResponse: ((RGCxrBaseResponse) -> Void)?) {
        cxrImp.sendData(cmd: cmd, subCmd: subCmd, data: data, onResponse: onResponse)
    }

    /// 根据枚举发送命令到蓝牙设备
    /// - Parameters:
    ///   - cmd: 主指令
    ///   - subCmd: 副指令
    ///   - data: 数据
    ///   - onResponse: 设备回包
    public func send(cmd: RGCxrCmd,
                     subCmd: RGCxrSubCmd,
                     data: Any? = nil,
                     dataExt: Any? = nil,
                     onResponse: ((RGCxrBaseResponse) -> Void)? = nil) {
        var requestData: [Any] = [subCmd.rawValue]
        if let data = data {
            requestData.append(data)
        }
        if let dataExt = dataExt {
            requestData.append(dataExt)
        }
        cxrImp.sendData(cmd: cmd.rawValue, subCmd: subCmd.rawValue, data: requestData, onResponse: onResponse)
    }

    /// 开启眼镜的音频采集
    /// - Parameter type: 采集类型，会在onStartAudioStream回调中返回
    public func openAudioRecord(type: String, codec: RGCxrAudioCodec, mode: RGCxrAudioMode, denoiseMode: Int32 = -1, rokidDtlnAEC: Bool = false, rokidBF: Bool = false) {
        cxrImp.openAudioRecord(type: type, codec: codec, mode: mode, denoiseMode: denoiseMode, rokidDtlnAEC: rokidDtlnAEC, rokidBF: rokidBF)
    }

    public func openAudioRecord(type: String, codec: UInt32, mode: UInt32, denoiseMode: Int32 = -1, rokidDtlnAEC: Bool = false, rokidBF: Bool = false) {
        cxrImp.openAudioRecord(type: type, codec: RGCxrAudioCodec(rawValue: codec) ?? .pcm, mode: RGCxrAudioMode(rawValue: mode) ?? .antClose, denoiseMode: denoiseMode, rokidDtlnAEC: rokidDtlnAEC, rokidBF: rokidBF)
    }

    /// 关闭眼镜的音频采集
    /// - Parameter type: 采集类型，与startAudioStream对应
    public func closeAudioRecord(type: String) {
        cxrImp.closeAudioRecord(type: type)
    }

    /// 通知眼镜手机即将发送音频
    /// - Parameters:
    ///   - streamId: 音频流ID
    ///   - prio: 播放优先级, 若同时有多个音频传输到眼镜端, prio数值最低的100%音量, 其它40%音量播放
    ///   - speed: 播放速率, 1.0为原始速度, 数值越大播放越快
    ///   - codec: 1: pcm, 传输时sdk将其转为ogg-opus
    public func startPlayAudio(streamId: Int, prio: Int32, speed: Float, codec: RGCxrAudioCodec) {
        cxrImp.startPlayAudio(streamId: UInt32(streamId), prio: prio, speed: speed, codec: codec)

    }

    /// 发送音频到眼镜
    /// - Parameters:
    ///   - streamId: 音频流ID
    ///   - data: 音频数据
    public func sendAudioStream(streamId: Int, data: Data) {
        cxrImp.sendAudioStream(streamId: streamId, data: data)
    }

    /// 告知眼镜停止播放音频
    /// - Parameter streamId: 音频流ID
    public func cancelAudioPlay(streamId: Int) {
        cxrImp.cancelAudioPlay(streamId: streamId)
    }

    /// 告知眼镜音频发送完了
    /// - Parameter streamId: 音频流ID
    public func finishAudioStream(streamId: Int) {
        cxrImp.finishAudioStream(streamId: streamId)
    }

    /// 发送数据给眼镜
    /// - Parameters:
    ///   - cmd: cmd
    ///   - subCmd: subCmd
    ///   - args: 参数
    ///   - data: 数据
    public func sendStream(cmd: String, subCmd: String, args: Any?, data: Data) {
        cxrImp.sendStream(cmd: cmd, subCmd: subCmd, args: args, data: data)
    }

    /// 发送自定义流数据给眼镜，不额外写入 subCmd。
    public func sendStream(cmd: String, args: Any?, data: Data) {
        cxrImp.sendStream(cmd: cmd, args: args, data: data)
    }

    /// 根据枚举发送数据给眼镜
    /// - Parameters:
    ///   - cmd: cmd
    ///   - subCmd: subCmd
    ///   - args: 参数
    ///   - data: 数据
    public func sendStream(cmd: RGCxrCmd,
                           subCmd: RGCxrSubCmd,
                           args: Any? = nil,
                           data: Data) {
        cxrImp.sendStream(cmd: cmd.rawValue, subCmd: subCmd.rawValue, args: args, data: data)
    }

    /// 各种回调设置
    public func addConnectionDelegate(_ delegate: RGCxrConnectionDelegate) {
        cxrImp.addConnectionDelegate(delegate)
    }

    public func removeConnectionDelegate(_ delegate: RGCxrConnectionDelegate) {
        cxrImp.removeConnectionDelegate(delegate)
    }

    public func addScanDelegate(_ delegate: RGCxrScanDelegate) {
        cxrImp.addScanDelegate(delegate)
    }

    public func removeScanDelegate(_ delegate: RGCxrScanDelegate) {
        cxrImp.removeScanDelegate(delegate)
    }

    public func addDataDelegate(_ delegate: RGCxrDataDelegate) {
        cxrImp.addDataDelegate(delegate)
    }

    public func removeDataDelegate(_ delegate: RGCxrDataDelegate) {
        cxrImp.removeDataDelegate(delegate)
    }

    public func addCentralManagerDelegate(_ delegate: RGCxrCentralManagerDelegate) {
        cxrImp.addCentralManagerDelegate(delegate)
    }

    public func removeCentralManagerDelegate(_ delegate: RGCxrCentralManagerDelegate) {
        cxrImp.removeCentralManagerDelegate(delegate)
    }

    public func addAudioStreamDelegate(_ delegate: RGCxrAudioStreamDelegate) {
        cxrImp.addAudioStreamDelegate(delegate)
    }

    public func removeAudioStreamDelegate(_ delegate: RGCxrAudioStreamDelegate) {
        cxrImp.removeAudioStreamDelegate(delegate)
    }
}
