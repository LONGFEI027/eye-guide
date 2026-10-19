//
//  RGCxrSessionImpl.swift
//  RGCxrClient
//
//  Created by Codex on 2026/6/6.
//

import Foundation
import Combine
import RGCoreKit

internal final class RGCxrSessionStateStore {
    internal static let shared = RGCxrSessionStateStore()

    private let lock = NSLock()
    private let stateSubject = CurrentValueSubject<RGCxrSessionStateEvent, Never>(
        RGCxrSessionStateEvent(state: .unavailable, reason: nil)
    )
    private let destroyedSubject = PassthroughSubject<Void, Never>()

    private var currentState: RGCxrSessionState = .unavailable
    private var currentReason: RGCxrSessionStateReason?
    private var currentConfig: RGCxrSessionConfig?
    private var destroyed = false
    private var destroying = false
    private var audioStreamActive = false

    internal var state: RGCxrSessionState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    internal var reason: RGCxrSessionStateReason? {
        lock.lock()
        defer { lock.unlock() }
        return currentReason
    }

    internal var isDestroyed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destroyed
    }

    internal var isDestroying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destroying
    }

    internal var config: RGCxrSessionConfig? {
        lock.lock()
        defer { lock.unlock() }
        return currentConfig
    }

    internal var statePublisher: AnyPublisher<RGCxrSessionStateEvent, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    internal var destroyedPublisher: AnyPublisher<Void, Never> {
        destroyedSubject.eraseToAnyPublisher()
    }

    internal func bind(config: RGCxrSessionConfig, bleConnected: Bool) {
        lock.lock()
        currentConfig = config
        destroyed = false
        destroying = false
        audioStreamActive = false
        lock.unlock()

        transition(to: bleConnected ? .available : .unavailable,
                   reason: bleConnected ? .linkConnected : .linkDisconnected,
                   force: true)
    }

    internal func markDestroying() {
        lock.lock()
        destroying = true
        lock.unlock()
    }

    internal func cancelDestroying() {
        lock.lock()
        destroying = false
        lock.unlock()
    }

    internal func markDestroyed() {
        lock.lock()
        destroying = false
        destroyed = true
        audioStreamActive = false
        lock.unlock()
        destroyedSubject.send(())
    }

    internal func markAudioStreamActive(_ active: Bool) {
        lock.lock()
        audioStreamActive = active
        lock.unlock()
    }

    internal func handleBLEConnected(_ connected: Bool) {
        if connected {
            guard state != .started else { return }
            transition(to: .available, reason: .linkConnected)
        } else {
            guard state != .unavailable else { return }
            transition(to: .paused, reason: .linkDisconnected)
        }
    }

    internal func handleCustomViewRunning(_ running: Bool) {
        guard currentConfig?.type == .customView else { return }
        if running {
            transition(to: .started, reason: .glassReady)
            return
        }
        guard !isDestroying else { return }
        transition(to: .unavailable, reason: .glassIdle)
    }

    internal func handleTargetAppResumed(_ resumed: Bool) {
        guard currentConfig?.type == .customApp else { return }
        if resumed {
            transition(to: .started, reason: .glassReady)
            return
        }
        guard !isDestroying, state == .started || state == .paused else { return }
        transition(to: .paused, reason: .other)
    }

    internal func handleLifecycleNotify(state: RGCxrSessionState, reason: RGCxrSessionStateReason?) {
        guard !isDestroying else { return }
        if state == .started, reason == .aiStop {
            transition(to: .available, reason: reason)
            return
        }
        transition(to: state, reason: reason)
    }

    @discardableResult
    internal func requireStarted(_ member: String) -> RGCxrClientError? {
        lock.lock()
        let destroyed = self.destroyed
        let state = currentState
        lock.unlock()

        if destroyed {
            RGLog.error("[CxrSession] \(member) session 已销毁，已忽略")
            return .sessionDestroyed
        }

        switch state {
        case .started:
            return nil
        case .paused:
            RGLog.error("[CxrSession] \(member) session 已暂停，已忽略")
            return .sessionPaused
        case .unavailable:
            RGLog.error("[CxrSession] \(member) session 不可用，已忽略")
            return .sessionUnavailable
        case .available:
            RGLog.error("[CxrSession] \(member) session 尚未 Started，已忽略")
            return .notReady
        }
    }

    private func transition(to state: RGCxrSessionState,
                            reason: RGCxrSessionStateReason?,
                            force: Bool = false) {
        lock.lock()
        if destroyed {
            lock.unlock()
            return
        }
        if !force, currentState == state {
            currentReason = reason
            lock.unlock()
            return
        }
        if state == .paused {
            audioStreamActive = false
        }
        currentState = state
        currentReason = reason
        let event = RGCxrSessionStateEvent(state: state, reason: reason)
        lock.unlock()
        stateSubject.send(event)
    }

    private init() {}
}

internal final class RGCxrLinkImpl: RGCxrLink {

    let events: RGCxrLinkEvents

    private let appDisplayName: String?
    private let client: RGCxrClient
    private let linkEvents: RGCxrLinkEventsImpl

    init(appDisplayName: String?, client: RGCxrClient) {
        self.appDisplayName = appDisplayName
        self.client = client
        self.linkEvents = RGCxrLinkEventsImpl(client: client)
        self.events = linkEvents
        initializeLinkIfNeeded()
    }

    func authenticate(scopes: [RGCxrClientAuthPermission],
                      completion: ((Result<(token: String, sessionId: String?), Error>) -> Void)?) {
        initializeLinkIfNeeded()
        client.auth.authenticate(scopes: scopes, appName: appDisplayName, completion: completion)
    }

    func handleOpenURL(_ url: URL) -> Bool {
        initializeLinkIfNeeded()
        return client.handleOpenURL(url)
    }

    func disconnect() {
        (client as? RGCxrClientImpl)?.ble.disconnect()
    }

    func makeCustomViewSession(aiInterceptMode: RGCxrAiInterceptMode) -> RGCxrCustomViewSession {
        let config = RGCxrSessionConfig(
            type: .customView,
            appDisplayName: appDisplayName,
            aiInterceptMode: aiInterceptMode
        )
        bindSessionMode(config: config)
        if let impl = client as? RGCxrClientImpl {
            RGCxrSessionStateStore.shared.bind(config: config, bleConnected: impl.ble.isConnected)
        }
        return RGCxrCustomViewSessionImpl(config: config, client: client)
    }

    func makeCustomAppSession(packageName: String, aiInterceptMode: RGCxrAiInterceptMode) -> RGCxrCustomAppSession {
        let config = RGCxrSessionConfig(
            type: .customApp,
            customAppPackageName: packageName,
            appDisplayName: appDisplayName,
            aiInterceptMode: aiInterceptMode
        )
        bindSessionMode(config: config)
        if let impl = client as? RGCxrClientImpl {
            RGCxrSessionStateStore.shared.bind(config: config, bleConnected: impl.ble.isConnected)
        }
        return RGCxrCustomAppSessionImpl(config: config, client: client)
    }

    private func initializeLinkIfNeeded() {
        let options = RGCxrClientInitializationOptions(appDisplayName: appDisplayName)
        _ = RGCxrClientLifecycle.performFirstInitialize(options: options) {
            _ = options
        }
    }

    private func bindSessionMode(config: RGCxrSessionConfig) {
        let mode = config.clientInitMode
        let options = config.initializationOptions
        let bound = RGCxrClientLifecycle.bindModeIfNeeded(mode: mode, options: options) { [client] in
            (client as? RGCxrClientImpl)?.applyInitialization(mode: mode, options: options)
        }
        if !bound {
            RGLog.error("[CxrLink] session 配置与当前 SDK 初始化配置不一致，已继续创建但后续调用会被前置条件拦截")
        }
    }
}

private final class RGCxrLinkEventsImpl: RGCxrLinkEvents {
    private let client: RGCxrClient

    init(client: RGCxrClient) {
        self.client = client
    }

    var authStatePublisher: AnyPublisher<RGCxrClientAuthState, Never> {
        client.auth.statePublisher
    }

    var authEventPublisher: AnyPublisher<RGCxrClientAuthEvent, Never> {
        client.auth.eventPublisher
    }

    var connectionStatePublisher: AnyPublisher<Bool, Never> {
        guard let impl = client as? RGCxrClientImpl else {
            return Empty<Bool, Never>(completeImmediately: false).eraseToAnyPublisher()
        }
        return impl.ble.connectionStatePublisher
    }
}

internal class RGCxrBaseSessionImpl: RGCxrSession {

    let config: RGCxrSessionConfig
    let device: RGCxrSessionDevice
    let media: RGCxrSessionMedia
    let ai: RGCxrSessionAI
    var state: RGCxrSessionState {
        RGCxrSessionStateStore.shared.state
    }
    var statePublisher: AnyPublisher<RGCxrSessionStateEvent, Never> {
        RGCxrSessionStateStore.shared.statePublisher
    }
    var destroyedPublisher: AnyPublisher<Void, Never> {
        RGCxrSessionStateStore.shared.destroyedPublisher
    }
    let deviceEvents: RGCxrSessionDeviceEvents
    let mediaEvents: RGCxrSessionMediaEvents
    let aiEvents: RGCxrSessionAIEvents

    fileprivate let client: RGCxrClient
    fileprivate let imageEventSubject: PassthroughSubject<RGCxrSessionImageEvent, Never>
    fileprivate let aiAssistEventSubject: PassthroughSubject<RGCxrSessionAiAssistEvent, Never>

    init(config: RGCxrSessionConfig, client: RGCxrClient) {
        let imageEventSubject = PassthroughSubject<RGCxrSessionImageEvent, Never>()
        let aiAssistEventSubject = PassthroughSubject<RGCxrSessionAiAssistEvent, Never>()
        self.config = config
        self.client = client
        self.imageEventSubject = imageEventSubject
        self.aiAssistEventSubject = aiAssistEventSubject
        self.device = RGCxrSessionDeviceImpl(config: config, client: client)
        self.media = RGCxrSessionMediaImpl(config: config, client: client, imageEventSubject: imageEventSubject)
        self.ai = RGCxrSessionAIImpl(config: config, client: client)
        self.deviceEvents = RGCxrSessionDeviceEventsImpl(client: client)
        self.mediaEvents = RGCxrSessionMediaEventsImpl(client: client, imageEventSubject: imageEventSubject)
        self.aiEvents = RGCxrSessionAIEventsImpl(client: client, aiAssistEventSubject: aiAssistEventSubject)
    }

    @discardableResult
    func destroy(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        RGCxrSessionStateStore.shared.markDestroying()
        if config.aiInterceptMode == .blockAI {
            _ = client.interruptAiWake(false, callback: nil)
        }

        switch config.type {
        case .customView:
            let err = client.closeCustomView { success in
                if success {
                    RGCxrSessionStateStore.shared.markDestroyed()
                } else {
                    RGCxrSessionStateStore.shared.cancelDestroying()
                }
                callback?(success)
            }
            if err == .notReady || err == .sessionUnavailable {
                RGCxrSessionStateStore.shared.markDestroyed()
                callback?(true)
                return nil
            }
            if err != nil {
                RGCxrSessionStateStore.shared.cancelDestroying()
            }
            return err
        case .customApp:
            let err = client.stopApp { success in
                if success {
                    RGCxrSessionStateStore.shared.markDestroyed()
                } else {
                    RGCxrSessionStateStore.shared.cancelDestroying()
                }
                callback?(success)
            }
            if err == .notReady || err == .sessionUnavailable {
                RGCxrSessionStateStore.shared.markDestroyed()
                callback?(true)
                return nil
            }
            if err != nil {
                RGCxrSessionStateStore.shared.cancelDestroying()
            }
            return err
        }
    }
}

internal final class RGCxrCustomViewSessionImpl: RGCxrBaseSessionImpl, RGCxrCustomViewSession {
    let customView: RGCxrSessionCustomView
    let customViewEvents: RGCxrCustomViewEvents

    private let customViewEventSubject: PassthroughSubject<RGCxrSessionCustomViewEvent, Never>
    private var cancellables = Set<AnyCancellable>()

    override init(config: RGCxrSessionConfig, client: RGCxrClient) {
        let customViewEventSubject = PassthroughSubject<RGCxrSessionCustomViewEvent, Never>()
        self.customViewEventSubject = customViewEventSubject
        self.customView = RGCxrSessionCustomViewImpl(
            config: config,
            client: client,
            customViewEventSubject: customViewEventSubject
        )
        self.customViewEvents = RGCxrCustomViewEventsImpl(customViewEventSubject: customViewEventSubject)
        super.init(config: config, client: client)
        bindCustomViewEvents()
    }

    private func bindCustomViewEvents() {
        client.customViewRunningEventPublisher
            .sink { [weak self] event in
                self?.customViewEventSubject.send(event.isRunning ? .opened : .closed)
            }
            .store(in: &cancellables)
    }
}

internal final class RGCxrCustomAppSessionImpl: RGCxrBaseSessionImpl, RGCxrCustomAppSession {
    let app: RGCxrSessionApp
    let commands: RGCxrSessionCommands
    let appEvents: RGCxrCustomAppEvents
    let commandEvents: RGCxrCommandEvents

    override init(config: RGCxrSessionConfig, client: RGCxrClient) {
        self.app = RGCxrSessionAppImpl(config: config, client: client)
        self.commands = RGCxrSessionCommandsImpl(config: config, client: client)
        self.appEvents = RGCxrCustomAppEventsImpl(config: config, client: client)
        self.commandEvents = RGCxrCommandEventsImpl(client: client)
        super.init(config: config, client: client)
    }
}

private final class RGCxrSessionDeviceImpl: RGCxrSessionDevice {
    private let config: RGCxrSessionConfig
    private let client: RGCxrClient

    init(config: RGCxrSessionConfig, client: RGCxrClient) {
        self.config = config
        self.client = client
    }

    @discardableResult
    func getGlassDeviceInfo(callback: ((RGCxrDeviceInfo?) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "device.getGlassDeviceInfo") { return err }
        return client.getDeviceInfo(callback: callback)
    }

    @discardableResult
    func isWearingCheckOn(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "device.isWearingCheckOn") { return err }
        return client.getWearingSwitch(callback: callback)
    }

    @discardableResult
    func setBrightness(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "device.setBrightness") { return err }
        return client.setBrightness(level: level, callback: callback)
    }

    @discardableResult
    func getBrightness(callback: ((Int?) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "device.getBrightness") { return err }
        return client.getBrightness(callback: callback)
    }

    @discardableResult
    func setVolume(level: Int, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "device.setVolume") { return err }
        return client.setVolume(level: level, callback: callback)
    }

    @discardableResult
    func getVolume(callback: ((Int?) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "device.getVolume") { return err }
        return client.getVolume(callback: callback)
    }
}

private final class RGCxrSessionMediaImpl: RGCxrSessionMedia {
    private let config: RGCxrSessionConfig
    private let client: RGCxrClient
    private let imageEventSubject: PassthroughSubject<RGCxrSessionImageEvent, Never>

    init(config: RGCxrSessionConfig,
         client: RGCxrClient,
         imageEventSubject: PassthroughSubject<RGCxrSessionImageEvent, Never>) {
        self.config = config
        self.client = client
        self.imageEventSubject = imageEventSubject
    }

    @discardableResult
    func startAudioStream(codec: RGCxrAudioCodec, mode: RGCxrAudioMode) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "media.startAudioStream") { return err }
        let err = client.startRecord("stream", codec: codec, mode: mode)
        if err == nil {
            RGCxrSessionStateStore.shared.markAudioStreamActive(true)
        }
        return err
    }

    @discardableResult
    func stopAudioStream() -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        let err = client.stopRecord("stream")
        if err == nil {
            RGCxrSessionStateStore.shared.markAudioStreamActive(false)
        }
        return err
    }

    @discardableResult
    func startPlayAudio(codec: RGCxrAudioCodec) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "media.startPlayAudio") { return err }
        return client.startPlayAudio(codec: codec)
    }

    @discardableResult
    func stopPlayAudio() -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.stopPlayAudio()
    }

    @discardableResult
    func feedAudio(_ data: Data) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "media.feedAudio") { return err }
        return client.feedAudio(data)
    }

    @discardableResult
    func takePhoto() -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "media.takePhoto") { return err }
        return client.takePhoto()
    }

    @discardableResult
    func takePhoto(width: Int, height: Int, quality: Int, callback: ((Data) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "media.takePhoto") { return err }
        return client.takePhotoWithData(width: width, height: height, quality: quality) { [weak self] data in
            self?.imageEventSubject.send(.received(data))
            callback?(data)
        }
    }

    @discardableResult
    func changeAudioSceneId(_ audioSceneId: RGCxrAudioSceneId, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "media.changeAudioSceneId") { return err }
        return client.changeAudioSceneId(audioSceneId, callback: callback)
    }
}

private final class RGCxrSessionAIImpl: RGCxrSessionAI {
    private let config: RGCxrSessionConfig
    private let client: RGCxrClient

    init(config: RGCxrSessionConfig, client: RGCxrClient) {
        self.config = config
        self.client = client
    }

    @discardableResult
    func sendExitAI(playSound: Bool, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "ai.sendExitAI") { return err }
        RGLog.warn("[CxrSession] sendExitAI 当前 iOS 底层协议尚未提供对等实现")
        callback?(false)
        return nil
    }

    @discardableResult
    func setInterruptAiWake(_ interruptWake: Bool, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.interruptAiWake(interruptWake, callback: callback)
    }
}

private final class RGCxrSessionCustomViewImpl: RGCxrSessionCustomView {
    private let config: RGCxrSessionConfig
    private let client: RGCxrClient
    private let customViewEventSubject: PassthroughSubject<RGCxrSessionCustomViewEvent, Never>

    init(config: RGCxrSessionConfig,
         client: RGCxrClient,
         customViewEventSubject: PassthroughSubject<RGCxrSessionCustomViewEvent, Never>) {
        self.config = config
        self.client = client
        self.customViewEventSubject = customViewEventSubject
    }

    @discardableResult
    func setIcons(_ iconData: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.sendCustomViewIcons(iconData) { [weak self] success in
            if success {
                self?.customViewEventSubject.send(.iconsSent)
            }
            callback?(success)
        }
    }

    @discardableResult
    func open(_ viewData: String,
              callback: ((_ success: Bool, _ errorCode: Int?) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.openCustomView(viewData) { [weak self] success, errorCode in
            if success, self?.config.aiInterceptMode == .blockAI {
                _ = self?.client.interruptAiWake(true, callback: nil)
            }
            callback?(success, errorCode)
        }
    }

    @discardableResult
    func update(_ viewData: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "customView.update") { return err }
        return client.updateCustomView(viewData) { [weak self] success in
            if success {
                self?.customViewEventSubject.send(.updated)
            }
            callback?(success)
        }
    }

    @discardableResult
    func close(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.closeCustomView(callback: callback)
    }
}

private final class RGCxrSessionAppImpl: RGCxrSessionApp {
    private let config: RGCxrSessionConfig
    private let client: RGCxrClient

    init(config: RGCxrSessionConfig, client: RGCxrClient) {
        self.config = config
        self.client = client
    }

    @discardableResult
    func uploadAndInstall(path: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.installApp(path, callback: callback)
    }

    @discardableResult
    func uninstall(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.uninstallApp(callback: callback)
    }

    @discardableResult
    func start(activityName: String,
               interruptAiWake: Bool,
               callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        let shouldInterruptAi = interruptAiWake || config.aiInterceptMode == .blockAI
        let err = client.openApp(activityName: activityName, url: "") { [weak self] success in
            if success {
                _ = self?.client.interruptAiWake(shouldInterruptAi, callback: nil)
            }
            callback?(success)
        }
        return err
    }

    @discardableResult
    func start(activityName: String, callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        start(activityName: activityName, interruptAiWake: config.aiInterceptMode == .blockAI, callback: callback)
    }

    @discardableResult
    func stop(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        let err = client.stopApp { [weak self] success in
            if success {
                _ = self?.client.interruptAiWake(false, callback: nil)
            }
            callback?(success)
        }
        return err
    }

    @discardableResult
    func isInstalled(callback: ((Bool) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.queryApp(callback: callback)
    }
}

private final class RGCxrSessionCommandsImpl: RGCxrSessionCommands {
    private let config: RGCxrSessionConfig
    private let client: RGCxrClient

    init(config: RGCxrSessionConfig, client: RGCxrClient) {
        self.config = config
        self.client = client
    }

    @discardableResult
    func setNotifyEventListenCmds(_ cmds: [String]) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        return client.setNotifyEventListenCmds(cmds)
    }

    @discardableResult
    func send(cmd: String,
              payload: Data?,
              callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "commands.send") { return err }
        return client.sendCustomCmd(cmd: cmd, payload: payload, callback: callback)
    }

    @discardableResult
    func send(cmd: String,
              payload: Data?,
              stream: Data,
              callback: ((_ success: Bool, _ payload: Data?, _ errorCode: Int32?, _ errorMsg: String?) -> Void)?) -> RGCxrClientError? {
        if let err = ensureSessionConfiguration(config, client: client) { return err }
        if let err = ensureSessionStarted(member: "commands.sendStream") { return err }
        return client.sendCustomCmdStream(cmd: cmd, payload: payload, stream: stream, callback: callback)
    }
}

private final class RGCxrSessionDeviceEventsImpl: RGCxrSessionDeviceEvents {
    private let client: RGCxrClient

    init(client: RGCxrClient) {
        self.client = client
    }

    var deviceInfoPublisher: AnyPublisher<RGCxrDeviceInfo, Never> {
        client.deviceInfoEventPublisher
    }

    var wearingStatusPublisher: AnyPublisher<Bool, Never> {
        client.wearingStatusEventPublisher
    }
}

private final class RGCxrSessionMediaEventsImpl: RGCxrSessionMediaEvents {
    private let client: RGCxrClient
    private let imageEventSubject: PassthroughSubject<RGCxrSessionImageEvent, Never>

    init(client: RGCxrClient,
         imageEventSubject: PassthroughSubject<RGCxrSessionImageEvent, Never>) {
        self.client = client
        self.imageEventSubject = imageEventSubject
    }

    var audioPublisher: AnyPublisher<RGCxrClientAudioEvent, Never> {
        client.audioEventPublisher
    }

    var imagePublisher: AnyPublisher<RGCxrSessionImageEvent, Never> {
        imageEventSubject.eraseToAnyPublisher()
    }
}

private final class RGCxrSessionAIEventsImpl: RGCxrSessionAIEvents {
    private let client: RGCxrClient
    private let aiAssistEventSubject: PassthroughSubject<RGCxrSessionAiAssistEvent, Never>

    init(client: RGCxrClient,
         aiAssistEventSubject: PassthroughSubject<RGCxrSessionAiAssistEvent, Never>) {
        self.client = client
        self.aiAssistEventSubject = aiAssistEventSubject
    }

    var aiAssistPublisher: AnyPublisher<RGCxrSessionAiAssistEvent, Never> {
        aiAssistEventSubject.eraseToAnyPublisher()
    }

    var aiWakeInterruptPublisher: AnyPublisher<Bool, Never> {
        client.aiWakeInterruptEventPublisher
    }
}

private final class RGCxrCustomViewEventsImpl: RGCxrCustomViewEvents {
    private let customViewEventSubject: PassthroughSubject<RGCxrSessionCustomViewEvent, Never>

    init(customViewEventSubject: PassthroughSubject<RGCxrSessionCustomViewEvent, Never>) {
        self.customViewEventSubject = customViewEventSubject
    }

    var lifecyclePublisher: AnyPublisher<RGCxrSessionCustomViewEvent, Never> {
        customViewEventSubject.eraseToAnyPublisher()
    }
}

private final class RGCxrCustomAppEventsImpl: RGCxrCustomAppEvents {
    private let config: RGCxrSessionConfig
    private let client: RGCxrClient

    init(config: RGCxrSessionConfig, client: RGCxrClient) {
        self.config = config
        self.client = client
    }

    var resumePublisher: AnyPublisher<Bool, Never> {
        client.appResumeChangeEventPublisher
            .map { [config] event in
                guard let packageName = config.customAppPackageName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !packageName.isEmpty else {
                    return false
                }
                return event.packageName == packageName
            }
            .eraseToAnyPublisher()
    }
}

private final class RGCxrCommandEventsImpl: RGCxrCommandEvents {
    private let client: RGCxrClient

    init(client: RGCxrClient) {
        self.client = client
    }

    var notifyPublisher: AnyPublisher<RGCxrClientNotifyEvent, Never> {
        client.notifyEventPublisher
    }
}

private func ensureSessionConfiguration(_ config: RGCxrSessionConfig, client: RGCxrClient) -> RGCxrClientError? {
    guard let snapshot = RGCxrClientLifecycle.snapshot else {
        RGLog.error("[CxrSession] SDK 未初始化，已忽略调用")
        return .notInitialized
    }
    guard snapshot.mode == config.clientInitMode else {
        RGLog.error("[CxrSession] session 模式与当前 SDK 初始化模式不一致，已忽略调用")
        return .modeMismatch
    }
    let expected = config.customAppPackageName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let actual = snapshot.options.pageName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if config.type == .customApp, expected != actual {
        RGLog.error("[CxrSession] customApp packageName 与当前 SDK 初始化配置不一致，已忽略调用")
        return .modeMismatch
    }
    _ = client
    return nil
}

private func ensureSessionStarted(member: String) -> RGCxrClientError? {
    RGCxrSessionStateStore.shared.requireStarted(member)
}

private extension RGCxrSessionConfig {
    var clientInitMode: RGCxrClientInitMode {
        switch type {
        case .customView:
            return .customView
        case .customApp:
            return .customApp
        }
    }

    var initializationOptions: RGCxrClientInitializationOptions {
        RGCxrClientInitializationOptions(
            appDisplayName: appDisplayName,
            pageName: customAppPackageName
        )
    }
}
