import AuthenticationServices
import CryptoKit
import Foundation
import GrokBotWatchCore
import Security
import UIKit

enum LinkFailure: Error {
    case configuration, signedOut, invalidResponse, network, cancelled
}

struct DeviceSHA256: PKCEHasher {
    func sha256(_ input: Data) throws -> Data { Data(SHA256.hash(data: input)) }
}

/// Limits apply while reading. Auth responses and conversation contents never enter a disk cache.
final class ServiceHTTP: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func read(_ request: URLRequest, limit: Int = 1_048_576) async throws -> (Int, Data) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse else { throw LinkFailure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { return (response.statusCode, Data()) }
        guard response.expectedContentLength <= Int64(limit) else { throw LinkFailure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw LinkFailure.invalidResponse }
            data.append(byte)
        }
        return (response.statusCode, data)
    }
}

struct PhoneCredential: Codable, Sendable {
    let access: String
    let refresh: String
    let team: Int64?
}

actor DeviceAccount: TokenStore, AuthTransport {
    private let http = ServiceHTTP()
    private let backend = URL(string: "https://api2.cursor.sh")!
    private var loginID: UUID?
    private var generation = UUID()
    private var pendingCredential: PhoneCredential?

    // Use the provider-issued configuration for this companion.
    private let loginTarget = Bundle.main.object(forInfoDictionaryKey: "GrokBotLoginTarget") as? String
    private let clientID = Bundle.main.object(forInfoDictionaryKey: "GrokBotOAuthClientID") as? String
    var hasLoginConfiguration: Bool {
        guard let target = loginTarget, target.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              let clientID, !clientID.isEmpty, !clientID.contains("$(") else { return false }
        return true
    }

    func authorizationURL(challenge: String) throws -> URL {
        guard hasLoginConfiguration, let loginTarget else { throw LinkFailure.configuration }
        let id = UUID()
        cancelLogin()
        loginID = id
        var parts = URLComponents(string: "https://cursor.com/loginDeepControl")!
        parts.queryItems = [URLQueryItem(name: "challenge", value: challenge),
                            URLQueryItem(name: "uuid", value: id.uuidString.lowercased()),
                            URLQueryItem(name: "mode", value: "login"),
                            URLQueryItem(name: "redirectTarget", value: loginTarget),
                            URLQueryItem(name: "supportsSelectedTeamLogin", value: "true")]
        guard let url = parts.url else { throw LinkFailure.configuration }
        return url
    }

    func cancelLogin() {
        generation = UUID()
        loginID = nil
        pendingCredential = nil
    }

    private func stage(_ credential: PhoneCredential) -> SessionToken {
        pendingCredential = credential
        return SessionToken(access: credential.access, refresh: credential.refresh)
    }

    func poll(verifier: String) async throws -> AuthorizationPoll {
        guard let id = loginID else { return .expired }
        var parts = URLComponents(url: backend.appending(path: "auth/poll"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "uuid", value: id.uuidString.lowercased()),
                            URLQueryItem(name: "verifier", value: verifier)]
        let (code, data) = try await http.read(URLRequest(url: parts.url!), limit: 65_536)
        guard loginID == id else { return .expired }
        switch code {
        case 404: return .waiting
        case 401, 403: loginID = nil; return .denied
        case 200:
            struct Grant: Decodable { let accessToken: String; let refreshToken: String; let selectedTeamId: Int64? }
            let grant = try JSONDecoder().decode(Grant.self, from: data)
            guard Self.valid(grant.accessToken), Self.valid(grant.refreshToken),
                  (grant.selectedTeamId ?? 0) >= 0 else { throw LinkFailure.invalidResponse }
            loginID = nil
            let credential = PhoneCredential(access: grant.accessToken, refresh: grant.refreshToken, team: grant.selectedTeamId)
            return .authorized(stage(credential))
        default: throw LinkFailure.network
        }
    }

    func refresh(_ token: SessionToken) async throws -> SessionToken {
        guard hasLoginConfiguration, let clientID else { throw LinkFailure.configuration }
        guard let stored = try credentials(), stored.access == token.access, stored.refresh == token.refresh else {
            throw LinkFailure.signedOut
        }
        let started = generation
        var request = URLRequest(url: backend.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": token.refresh])
        let (code, data) = try await http.read(request, limit: 65_536)
        guard generation == started else { throw LinkFailure.cancelled }
        guard code == 200 else { throw LinkFailure.signedOut }
        struct Grant: Decodable { let access_token: String; let refresh_token: String? }
        let grant = try JSONDecoder().decode(Grant.self, from: data)
        guard Self.valid(grant.access_token), Self.valid(grant.refresh_token ?? token.refresh) else { throw LinkFailure.invalidResponse }
        return stage(PhoneCredential(access: grant.access_token, refresh: grant.refresh_token ?? token.refresh, team: stored.team))
    }

    private static func valid(_ string: String) -> Bool {
        !string.isEmpty && string.utf8.count <= 32_768 && !string.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "GrokBotWatch") + ".grok-account",
         kSecAttrAccount as String: "active", kSecAttrSynchronizable as String: false]
    }

    func credentials() throws -> PhoneCredential? {
        var read = query
        read[kSecReturnData as String] = true
        var found: CFTypeRef?
        let code = SecItemCopyMatching(read as CFDictionary, &found)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = found as? Data else { throw LinkFailure.signedOut }
        return try JSONDecoder().decode(PhoneCredential.self, from: data)
    }

    func load() throws -> SessionToken? {
        try credentials().map { SessionToken(access: $0.access, refresh: $0.refresh) }
    }

    func save(_ token: SessionToken) throws {
        guard let record = pendingCredential, record.access == token.access, record.refresh == token.refresh else {
            throw LinkFailure.cancelled
        }
        defer { pendingCredential = nil }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(record),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let code = update == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : update
        guard code == errSecSuccess else { throw LinkFailure.signedOut }
    }

    func clear() throws {
        cancelLogin()
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw LinkFailure.signedOut }
    }
}

@MainActor
final class LoginBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var sessionID: UUID?

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func open(_ url: URL, onDismiss: @escaping @MainActor () -> Void) throws {
        guard session == nil, anchor.windowScene?.activationState == .foregroundActive else { throw LinkFailure.cancelled }
        let id = UUID()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                self.session = nil
                self.sessionID = nil
                onDismiss()
            }
        }
        session.presentationContextProvider = self
        self.session = session
        sessionID = id
        guard session.start() else {
            close()
            throw LinkFailure.cancelled
        }
    }
    func close() {
        sessionID = nil
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
