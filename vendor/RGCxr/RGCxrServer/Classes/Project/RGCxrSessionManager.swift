import Foundation
import RGCoreKit
import Combine

internal struct RGCxrInternalSessionInfo {
    internal let bundleId: String
    internal let token: String
    internal let sessionId: String
    internal let createdAt: TimeInterval
    internal var isActive: Bool
    internal let metadata: [String: String]?
    
    internal init(bundleId: String, token: String, sessionId: String, metadata: [String: String]? = nil) {
        self.bundleId = bundleId
        self.token = token
        self.sessionId = sessionId
        self.createdAt = Date().timeIntervalSince1970
        self.isActive = true
        self.metadata = metadata
    }
}

internal enum RGCxrSessionEvent {
    case sessionCreated(session: RGCxrInternalSessionInfo)
    case sessionActivated(session: RGCxrInternalSessionInfo)
    case sessionDeactivated(session: RGCxrInternalSessionInfo)
    case sessionRevoked(bundleId: String)
}

internal final class RGCxrSessionManager {
    
    internal static let shared = RGCxrSessionManager()
    
    private let eventSubject = PassthroughSubject<RGCxrSessionEvent, Never>()
    internal var eventPublisher: AnyPublisher<RGCxrSessionEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }
    
    private var sessions: [String: RGCxrInternalSessionInfo] = [:]
    private var activeSessionId: String?
    private let lock = NSLock()
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupAuthManagerObserver()
        RGLog.info("[SessionManager] Session manager initialized")
    }
    
    internal var activeSession: RGCxrInternalSessionInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let activeId = activeSessionId else { return nil }
        return sessions[activeId]
    }
    
    internal var allSessions: [RGCxrInternalSessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }
    
    internal func getSession(for bundleId: String) -> RGCxrInternalSessionInfo? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[bundleId]
    }
    
    internal func createSession(bundleId: String, token: String, metadata: [String: String]? = nil) -> RGCxrInternalSessionInfo {
        lock.lock()
        defer { lock.unlock() }
        
        let sessionId = generateSessionId()
        
        if let previousActiveId = activeSessionId,
           previousActiveId != bundleId,
           var previousSession = sessions[previousActiveId] {
            previousSession.isActive = false
            sessions[previousActiveId] = previousSession
            RGLog.info("[SessionManager] Session \(previousActiveId) deactivated")
            eventSubject.send(.sessionDeactivated(session: previousSession))
        }
        
        for (key, var session) in sessions where key != bundleId && session.isActive {
            session.isActive = false
            sessions[key] = session
            RGLog.info("[SessionManager] Session \(key) deactivated")
            eventSubject.send(.sessionDeactivated(session: session))
        }
        
        var newSession = RGCxrInternalSessionInfo(bundleId: bundleId, token: token, sessionId: sessionId, metadata: metadata)
        newSession.isActive = true
        sessions[bundleId] = newSession
        activeSessionId = bundleId
        
        RGLog.info("[SessionManager] Session created and activated for \(bundleId)")
        eventSubject.send(.sessionCreated(session: newSession))
        eventSubject.send(.sessionActivated(session: newSession))
        
        return newSession
    }
    
    internal func activateSession(for bundleId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard var session = sessions[bundleId] else {
            RGLog.warn("[SessionManager] Session not found for \(bundleId)")
            return false
        }
        
        if let previousActiveId = activeSessionId,
           previousActiveId != bundleId,
           var previousSession = sessions[previousActiveId] {
            previousSession.isActive = false
            sessions[previousActiveId] = previousSession
            eventSubject.send(.sessionDeactivated(session: previousSession))
        }
        
        session.isActive = true
        sessions[bundleId] = session
        activeSessionId = bundleId
        
        RGLog.info("[SessionManager] Session activated for \(bundleId)")
        eventSubject.send(.sessionActivated(session: session))
        
        return true
    }
    
    internal func revokeSession(for bundleId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard sessions[bundleId] != nil else { return }
        
        if activeSessionId == bundleId {
            activeSessionId = nil
        }
        
        sessions.removeValue(forKey: bundleId)
        RGLog.info("[SessionManager] Session revoked for \(bundleId)")
        eventSubject.send(.sessionRevoked(bundleId: bundleId))
    }
    
    internal func validateSession(bundleId: String, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let session = sessions[bundleId] else { return false }
        return session.token == token
    }
    
    internal func clearAllSessions() {
        lock.lock()
        defer { lock.unlock() }
        
        let bundleIds = sessions.keys
        for bundleId in bundleIds {
            eventSubject.send(.sessionRevoked(bundleId: bundleId))
        }
        
        sessions.removeAll()
        activeSessionId = nil
        RGLog.info("[SessionManager] All sessions cleared")
    }
    
    private func generateSessionId() -> String {
        "session_\(UUID().uuidString)_\(Int(Date().timeIntervalSince1970))"
    }
    
    private func setupAuthManagerObserver() {
        RGCxrAuthManager.shared.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleAuthEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleAuthEvent(_ event: RGCxrAuthEvent) {
        switch event {
        case .authorized(let bundleId, let token):
            RGLog.info("[SessionManager] Auth authorized, creating session for \(bundleId)")
            _ = createSession(bundleId: bundleId, token: token)
            
        case .expired(let bundleId):
            RGLog.info("[SessionManager] Auth expired, revoking session for \(bundleId)")
            revokeSession(for: bundleId)
            
        case .denied(let bundleId, _):
            RGLog.info("[SessionManager] Auth denied, revoking session for \(bundleId)")
            revokeSession(for: bundleId)
            
        case .authorizationRequired:
            break
        }
    }
}