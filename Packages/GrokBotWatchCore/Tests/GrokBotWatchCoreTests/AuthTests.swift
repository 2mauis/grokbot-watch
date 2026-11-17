import Foundation
import GrokBotWatchCore
import Testing

struct SampleHasher: PKCEHasher {
    func sha256(_ input: Data) -> Data {
        // RFC 7636 Appendix B vector, applied only to the matching input.
        guard String(decoding: input, as: UTF8.self) == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" else { return Data(repeating: 0, count: 32) }
        return Data(base64Encoded: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw+cM=")!
    }
}

actor TestTokenStore: TokenStore {
    private var token: SessionToken?
    func load() -> SessionToken? { token }
    func save(_ token: SessionToken) { self.token = token }
    func clear() { token = nil }
}

actor TestAuth: AuthTransport {
    private var replies: [AuthorizationPoll]
    private(set) var refreshCount = 0
    init(_ replies: [AuthorizationPoll] = []) { self.replies = replies }

    func poll(verifier: String) throws -> AuthorizationPoll {
        #expect(verifier.count == 43)
        guard !replies.isEmpty else { throw TestFailure.missingResponse }
        return replies.removeFirst()
    }

    func refresh(_ token: SessionToken) throws -> SessionToken {
        refreshCount += 1
        throw TestFailure.disconnected
    }
}

@Suite struct AuthFlowTests {
    @Test func generatesVerifierAndEncodesSHA256AsRFC7636() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(try PKCE.challenge(for: verifier, using: SampleHasher()) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let new = try PKCE.generate(using: SampleHasher())
        #expect(new.verifier.count == 43)
        #expect(new.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(try PKCE.generate(using: SampleHasher()).verifier != new.verifier)
    }

    @Test func pollsUntilAuthorizedAndSignOutClearsStorage() async throws {
        let token = SessionToken(access: "sample-access", refresh: "sample-refresh")
        let store = TestTokenStore()
        let auth = AuthClient(transport: TestAuth([.waiting, .authorized(token)]), tokenStore: store)
        await auth.begin(try PKCE.generate(using: SampleHasher()))
        #expect(try await auth.poll() == .awaitingAuthorization)
        #expect(await store.load() == nil)
        #expect(try await auth.poll() == .signedIn)
        #expect(await store.load() == token)
        try await auth.signOut()
        #expect(await auth.state == .signedOut)
        #expect(await store.load() == nil)
    }

    @Test func deniedAuthorizationRequiresNewSignIn() async throws {
        let auth = AuthClient(transport: TestAuth([.denied]), tokenStore: TestTokenStore())
        await auth.begin(try PKCE.generate(using: SampleHasher()))
        #expect(try await auth.poll() == .needsLogin)
        #expect(try await auth.poll() == .needsLogin)
    }
}

@Suite struct AuthRefreshTests {
    @Test func uncertainRefreshRequiresSignInAndDoesNotRepeat() async throws {
        let store = TestTokenStore()
        let transport = TestAuth([.authorized(SessionToken(access: "sample-access", refresh: "sample-refresh"))])
        let auth = AuthClient(transport: transport, tokenStore: store)
        await auth.begin(try PKCE.generate(using: SampleHasher()))
        _ = try await auth.poll()
        #expect(try await auth.refresh() == .needsLogin)
        #expect(try await auth.refresh() == .needsLogin)
        #expect(await transport.refreshCount == 1)
    }
}
