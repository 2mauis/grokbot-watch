import Foundation

public protocol PKCEHasher: Sendable {
    func sha256(_ input: Data) throws -> Data
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public static func generate(using hasher: some PKCEHasher) throws -> PKCE {
        var random = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        let verifier = base64URL(Data(bytes))
        return PKCE(verifier: verifier, challenge: try challenge(for: verifier, using: hasher))
    }

    public static func challenge(for verifier: String, using hasher: some PKCEHasher) throws -> String {
        guard (43...128).contains(verifier.utf8.count),
              verifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95, 126].contains($0) })
        else { throw PKCEError.invalidVerifier }
        let digest = try hasher.sha256(Data(verifier.utf8))
        guard digest.count == 32 else { throw PKCEError.invalidDigest }
        return base64URL(digest)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum PKCEError: Error {
    case invalidVerifier
    case invalidDigest
}

public struct SessionToken: Equatable, Sendable {
    public let access: String
    public let refresh: String

    public init(access: String, refresh: String) {
        self.access = access
        self.refresh = refresh
    }

    fileprivate var isValid: Bool { !access.isEmpty && !refresh.isEmpty }
}

public protocol TokenStore: Sendable {
    func load() async throws -> SessionToken?
    func save(_ token: SessionToken) async throws
    func clear() async throws
}

public enum AuthState: String, Codable, Sendable {
    case signedOut
    case awaitingAuthorization
    case signedIn
    case needsLogin
}

public enum AuthorizationPoll: Sendable {
    case waiting
    case authorized(SessionToken)
    case denied
    case expired
}

public protocol AuthTransport: Sendable {
    func poll(verifier: String) async throws -> AuthorizationPoll
    func refresh(_ token: SessionToken) async throws -> SessionToken
}

public enum AuthError: Error {
    case busy
}

public actor AuthClient {
    public private(set) var state: AuthState = .signedOut

    private let transport: any AuthTransport
    private let tokenStore: any TokenStore
    private let clearCache: @Sendable () async throws -> Void
    private var verifier: String?
    private var busy = false
    private var signingOut = false
    private var signOutIncomplete = false
    private var idle: CheckedContinuation<Void, Never>?

    public init(
        transport: some AuthTransport,
        tokenStore: some TokenStore,
        clearCache: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.clearCache = clearCache
    }

    public func begin(_ pkce: PKCE) {
        guard !busy, !signingOut, !signOutIncomplete else { return }
        verifier = pkce.verifier
        state = .awaitingAuthorization
    }

    @discardableResult
    public func restore() async throws -> AuthState {
        guard state == .signedOut else { return state }
        try lock()
        defer { unlock() }
        if let token = try await tokenStore.load(), !signingOut {
            state = token.isValid ? .signedIn : .needsLogin
        }
        return state
    }

    @discardableResult
    public func poll() async throws -> AuthState {
        guard state == .awaitingAuthorization, let verifier else { return state }
        try lock()
        defer { unlock() }
        let reply = try await transport.poll(verifier: verifier)
        guard !signingOut else { return state }
        switch reply {
        case .waiting:
            break
        case .denied, .expired:
            requireLogin()
        case let .authorized(token):
            guard token.isValid else {
                requireLogin()
                return state
            }
            do {
                try await tokenStore.save(token)
                if !signingOut { state = .signedIn }
                self.verifier = nil
            } catch {
                requireLogin()
                throw error
            }
        }
        return state
    }

    @discardableResult
    public func refresh() async throws -> AuthState {
        guard state == .signedIn else { return state }
        try lock()
        defer { unlock() }
        do {
            guard let token = try await tokenStore.load(), token.isValid, !signingOut else {
                requireLogin()
                return state
            }
            let refreshed = try await transport.refresh(token)
            guard refreshed.isValid, !signingOut else {
                requireLogin()
                return state
            }
            try await tokenStore.save(refreshed)
        } catch {
            requireLogin()
        }
        return state
    }

    public func signOut() async throws {
        guard !signingOut else { throw AuthError.busy }
        signingOut = true
        signOutIncomplete = true
        defer { signingOut = false }
        verifier = nil
        if busy {
            await withCheckedContinuation { idle = $0 }
        }
        async let credentials: Void = tokenStore.clear()
        async let cache: Void = clearCache()
        do {
            _ = try await (credentials, cache)
            signOutIncomplete = false
            state = .signedOut
        } catch {
            requireLogin()
            throw error
        }
    }

    private func lock() throws {
        guard !busy, !signingOut else { throw AuthError.busy }
        busy = true
    }

    private func unlock() {
        busy = false
        idle?.resume()
        idle = nil
    }

    private func requireLogin() {
        verifier = nil
        state = .needsLogin
    }
}
