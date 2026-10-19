//
//  RGSocketAudioPlayer.swift
//  RGSDK
//
//  Created by Ginger on 2025/11/17.
//

import UIKit
import Combine
import RGCoreKit

public class RGSocketAudioStream: NSObject {
    
    // 唯一ID
    public var streamId: Int
    // 播放优先级，prio越小声音越大
    public var prio: Int32
    // 编码
    public var codec: RGCxrAudioCodec
    
    public init(streamId: Int, prio: Int32, codec: RGCxrAudioCodec) {
        self.streamId = streamId
        self.prio = prio
        self.codec = codec
        super.init()
    }
    
    fileprivate func startPlayAudio() {
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return
        }
        RGCxrKit.shared.startPlayAudio(streamId: streamId, prio: prio, speed: 1, codec: codec)
    }
    
    fileprivate func stopPlayAudio() {
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return
        }
        RGCxrKit.shared.cancelAudioPlay(streamId: streamId)
    }
    
    fileprivate func sendAudio(data: Data) {
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return
        }
        RGCxrKit.shared.sendAudioStream(streamId: streamId, data: data)
    }
    
    fileprivate func finishAudio() {
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return
        }
        RGCxrKit.shared.finishAudioStream(streamId: streamId)
    }
}

public class RGSocketAudioPlayer: NSObject {
    
    public static let shared = RGSocketAudioPlayer()
    
    private var streamId = 0
    
    private var streams: [RGSocketAudioStream] = []
    
    // MARK: - Combine Publishers
    
    /// 音频流事件类型
    public enum AudioStreamEvent {
        case startPlay(streamId: Int)
        case stopPlay(streamId: Int, code: Int)
        case endPlay(streamId: Int, code: Int)
    }
    
    /// 音频流事件发布者
    public let audioStreamEventSubject = PassthroughSubject<AudioStreamEvent, Never>()
    
    /// 音频流事件 Publisher（供外部订阅）
    public var audioStreamEventPublisher: AnyPublisher<AudioStreamEvent, Never> {
        audioStreamEventSubject.eraseToAnyPublisher()
    }
    
    private override init() {
        super.init()
        RGCxrKit.shared.addAudioStreamDelegate(self)
        RGCxrKit.shared.addConnectionDelegate(self)
    }
    
    public func playAudio(codec: RGCxrAudioCodec, completedCheck: (() -> Bool)? = nil) -> RGSocketAudioStream? {
        RGLog.api()
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return nil
        }
        let prio = getMinimumPrio() - 1
        streamId += 1
        let stream = RGSocketAudioStream(streamId: streamId, prio: prio, codec: codec)
        streams.append(stream)
        RGLog.info([
            "streamId": streamId,
        ])
        completedCheckMap[streamId] = completedCheck
        stream.startPlayAudio()
        return stream
    }
    
    public func stopPlayAudio(id: Int) {
        RGLog.api(id)
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return
        }
        if let stream = streams.first(where: { $0.streamId == id }) {
            stream.stopPlayAudio()
            resetTimer(streamId: id)
        } else {
            RGLog.warn("stream not exist")
            // 关闭要强制关
            RGCxrKit.shared.cancelAudioPlay(streamId: id)
        }
    }
    
    public func sendAudio(id: Int, data: Data, codec: RGCxrAudioCodec) {
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return
        }
        resetTimer(streamId: id)
        if let stream = streams.first(where: { $0.streamId == id }) {
            stream.sendAudio(data: data)
        } else {
            RGLog.warn("stream not exist")
//            let prio = getMinimumPrio() - 1
//            let stream = RGSocketAudioStream(streamId: id, prio: prio, codec: codec)
//            streams.append(stream)
//            stream.startPlayAudio()
//            stream.sendAudio(data: data)
        }
    }
    
    public func finishAudio(id: Int) {
        RGLog.api(id)
        guard RGCxrKit.shared.connectionStatus == .socketConnected else {
            RGLog.error("connectionStatus error: \(RGCxrKit.shared.connectionStatus)")
            return
        }
        if let stream = streams.first(where: { $0.streamId == id }) {
            streams.removeAll(where: { $0.streamId == streamId })
            // finish了说明已经完成了，不要再使用这个stream了
            stream.finishAudio()
            resetTimer(streamId: id)
        } else {
            RGLog.warn("stream not exist")
        }
    }
     
    /// 获取当前最小的prio，默认100
    public func getMinimumPrio() -> Int32 {
        guard !streams.isEmpty else {
            return 100
        }
        return streams.map { $0.prio }.min() ?? 100
    }
    
    
    public var completedCheckMap: [Int: (() -> Bool)] = [:]
    private var timers: [Int: Timer] = [:]

    private func startTimer(streamId: Int) {
        RGLog.api()
        if let completedCheck = completedCheckMap[streamId] {
            // 外部业务判断到已经完成，不需要再延时了，直接结束
            let ret = completedCheck()
            RGLog.info("completedCheck returned \(ret)")
            if ret {
                audioStreamEventSubject.send(.endPlay(streamId: streamId, code: 0))
            } else {
                RGLog.warn("completedCheck returned false, not stopping yet")
            }
        } else {
            RGLog.info("no completedCheck")
            resetTimer(streamId: streamId)
            streams.removeAll(where: { $0.streamId == streamId })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                    RGLog.info("complete timer")
                    guard let self else { return }
                    audioStreamEventSubject.send(.endPlay(streamId: streamId, code: 0))
                }
                timers[streamId] = timer
            }
        }
    }
    
    private func resetTimer(streamId: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let timer = timers.first(where: { $0.key == streamId }) {
                timer.value.invalidate()
                timers.removeValue(forKey: streamId)
            }
        }
    }
}

extension RGSocketAudioPlayer: RGCxrAudioStreamDelegate {
    public func onAudioStreamStartPlay(streamId: Int) {
        RGLog.info(streamId)
        audioStreamEventSubject.send(.startPlay(streamId: streamId))
    }
    
    public func onAudioStreamStopPlay(streamId: Int, code: Int) {
        RGLog.info(streamId)
        streams.removeAll(where: { $0.streamId == streamId })
        audioStreamEventSubject.send(.stopPlay(streamId: streamId, code: 0))
        startTimer(streamId: streamId)
    }
    
}

extension RGSocketAudioPlayer: RGCxrConnectionDelegate {
    public func onConnectionStatusChanged(old: RGCxrConnectionStatus, new: RGCxrConnectionStatus) {
        if old == .socketConnected,
           new != .socketConnected {
            streams.removeAll()
        }
    }
    
    public func onConnectionError(_ error: RGCxrConnectionError) {
    }
}
