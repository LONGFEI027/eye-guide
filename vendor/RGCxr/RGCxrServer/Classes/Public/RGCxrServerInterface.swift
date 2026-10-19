//
//  RGCxrServerInterface.swift
//  RGCxrServer
//
//  Created by Ginger on 2026/1/13.
//

import Foundation
import Combine

// MARK: - Public Types

/// Server 事件
public enum RGCxrServerEvent {
    case authorizationRequired(request: RGCxrAuthRequest, completion: (Bool) -> Void)
    case authorized(bundleId: String, token: String)
    case denied(bundleId: String, error: String)
    case error(Error)
}

/// Session 状态
public enum RGCxrSessionState {
    case active
    case inactive
}

/// Session 信息
public struct RGCxrSessionInfo {
    public let bundleId: String
    public let sessionId: String
    public let state: RGCxrSessionState
    public let createdAt: TimeInterval
}

/// 音频流开始信息
public struct RGCxrAudioStreamStartInfo {
    public let codec: Int32
    public let type: String
    public let channels: UInt32

    public init(codec: Int32, type: String, channels: UInt32) {
        self.codec = codec
        self.type = type
        self.channels = channels
    }
}

/// 音频流数据
public struct RGCxrAudioStreamData {
    public let data: Data
    public let timestamp: UInt64

    public init(data: Data, timestamp: UInt64) {
        self.data = data
        self.timestamp = timestamp
    }
}

/// CXR-L 会话相关场景快照。
public struct RGCxrServerSceneStatusSnapshot {
    public let aiAssistRunning: Bool
    public let aiChatRunning: Bool
    public let translateRunning: Bool
    public let wordTipsRunning: Bool
    public let paymentRunning: Bool
    public let cityGuideRunning: Bool
    public let jsaiRunning: Bool
    public let accessibilityRunning: Bool
    public let customViewRunning: Bool
    public let navigationRunning: Bool
    public let audioRecordRunning: Bool
    public let videoRecordRunning: Bool
    public let phoneCallRunning: Bool
    public let otaRunning: Bool
    public let takePictureRunning: Bool
    public let arPictureRunning: Bool
    public let mixRecordRunning: Bool
    public let liveBroadcastRunning: Bool
    public let musicWordRunning: Bool
    public let cameraPageRunning: Bool

    public init(aiAssistRunning: Bool = false,
                aiChatRunning: Bool = false,
                translateRunning: Bool = false,
                wordTipsRunning: Bool = false,
                paymentRunning: Bool = false,
                cityGuideRunning: Bool = false,
                jsaiRunning: Bool = false,
                accessibilityRunning: Bool = false,
                customViewRunning: Bool = false,
                navigationRunning: Bool = false,
                audioRecordRunning: Bool = false,
                videoRecordRunning: Bool = false,
                phoneCallRunning: Bool = false,
                otaRunning: Bool = false,
                takePictureRunning: Bool = false,
                arPictureRunning: Bool = false,
                mixRecordRunning: Bool = false,
                liveBroadcastRunning: Bool = false,
                musicWordRunning: Bool = false,
                cameraPageRunning: Bool = false) {
        self.aiAssistRunning = aiAssistRunning
        self.aiChatRunning = aiChatRunning
        self.translateRunning = translateRunning
        self.wordTipsRunning = wordTipsRunning
        self.paymentRunning = paymentRunning
        self.cityGuideRunning = cityGuideRunning
        self.jsaiRunning = jsaiRunning
        self.accessibilityRunning = accessibilityRunning
        self.customViewRunning = customViewRunning
        self.navigationRunning = navigationRunning
        self.audioRecordRunning = audioRecordRunning
        self.videoRecordRunning = videoRecordRunning
        self.phoneCallRunning = phoneCallRunning
        self.otaRunning = otaRunning
        self.takePictureRunning = takePictureRunning
        self.arPictureRunning = arPictureRunning
        self.mixRecordRunning = mixRecordRunning
        self.liveBroadcastRunning = liveBroadcastRunning
        self.musicWordRunning = musicWordRunning
        self.cameraPageRunning = cameraPageRunning
    }
}

/// 音频转发状态
public enum RGCxrAudioForwardingState {
    case started(port: UInt16)
    case clientConnected(bundleId: String)
    case clientDisconnected(bundleId: String)
    case stopped
}

// MARK: - Server Interface

/// Server 公开接口协议
public protocol RGCxrServer: AnyObject {

    var onGetPicConfig: (() -> (String, String))? { get set }

    var onGetVersion: (() -> Int)? { get set }

    var onGetDeviceInfo: (() -> RGCxrDeviceInfo?)? { get set }

    var onGetWearingSwitch: (() -> Bool)? { get set }

    var onGetSceneStatus: (() -> RGCxrServerSceneStatusSnapshot?)? { get set }

    var onGetScreenOn: (() -> Bool?)? { get set }

    var eventPublisher: AnyPublisher<RGCxrServerEvent, Never> { get }

    var sessionInfoPublisher: AnyPublisher<RGCxrSessionInfo, Never> { get }

    var activeSession: RGCxrSessionInfo? { get }

    var allSessions: [RGCxrSessionInfo] { get }

    func revokeAuthorization(for bundleId: String)

    func revokeAllAuthorizations()

    func handleOpenURL(_ url: URL) -> Bool

    func canHandleURL(_ url: URL) -> Bool

    func setActiveDeviceNameProvider(_ provider: @escaping () -> String?)

    func updateSceneStatus(_ status: RGCxrServerSceneStatusSnapshot)

    func updateScreenOn(_ screenOn: Bool)
}

// MARK: - Public Access

/// CXR Server 单例访问
public final class CxrServer {

    public static var shared: RGCxrServer {
        RGCxrServerImpl.shared
    }

    private init() {}
}
