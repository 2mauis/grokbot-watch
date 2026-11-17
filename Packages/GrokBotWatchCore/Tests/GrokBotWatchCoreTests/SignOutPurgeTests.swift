import Foundation
import GrokBotWatchCore
import Testing

@Suite struct SignOutPurgeTests {
    @Test func signOutClearsBothCachesWithoutRestoringOldEntriesOnNextSave() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let http = try TestHTTP([response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: storage.phone)
        let watch = try WatchOutbox(store: storage.watch)
        let old = try await watch.enqueue(messageAttempt().payload, opID: exampleID)
        _ = try await phone.receive(old, for: exampleBot)
        _ = try await phone.receive(messageAttempt(3), for: exampleBot)

        let credentials = TestTokenStore()
        await credentials.save(SessionToken(access: "sample-access", refresh: "sample-refresh"))
        let auth = AuthClient(transport: TestAuth(), tokenStore: credentials) {
            try storage.phone.save([])
            try storage.watch.save([])
        }
        #expect(try await auth.restore() == .signedIn)
        #expect(try storage.phone.load().map(\.attempt) == [old])
        #expect(try storage.watch.load().map(\.attempt) == [old])

        try await auth.signOut()
        #expect(await auth.state == .signedOut)
        #expect(await credentials.load() == nil)
        #expect(await phone.recentResults().isEmpty)
        #expect(await watch.record(for: old.opID) == nil)
        #expect(try storage.phone.load().isEmpty)
        #expect(try storage.watch.load().isEmpty)

        let fresh = try await watch.enqueue(messageAttempt().payload)
        #expect(try storage.watch.load().map(\.attempt) == [fresh])
    }

    @Test func signOutDuringWriteDiscardsOldCompletionWithoutSavingOrPublishing() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let gate = OperationGate()
        let http = try PausedHTTP(.send, produces: DeliveryStatus.accepted, gate: gate)
        let channel = TestWC()
        let phone = try relay(transport: http, store: storage.phone, wc: channel)
        let auth = AuthClient(transport: TestAuth(), tokenStore: TestTokenStore()) {
            try storage.phone.save([])
        }

        let write = Task { try await phone.receive(messageAttempt(), for: exampleBot) }
        await gate.waitUntilPaused()
        #expect(try storage.phone.load().map(\.attempt) == [messageAttempt()])
        do {
            try await auth.signOut()
            #expect(try storage.phone.load().isEmpty)
        } catch {
            await gate.open()
            throw error
        }
        await gate.open()

        #expect(try await write.value == nil)
        #expect(try storage.phone.load().isEmpty)
        #expect(await phone.recentResults().isEmpty)
        #expect(await channel.results.isEmpty)
    }

    @Test func signOutInvokesInjectedCacheCleanup() async throws {
        let calls = CacheCleanupCalls()
        let auth = AuthClient(transport: TestAuth(), tokenStore: TestTokenStore()) {
            await calls.record()
        }

        try await auth.signOut()
        #expect(await calls.count == 1)
    }
}

private struct LocalOperationStores {
    let directory: URL
    let phone: JSONOperationStore<RelayRecord>
    let watch: JSONOperationStore<WatchRecord>

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        phone = JSONOperationStore(url: directory.appendingPathComponent("relay.json"))
        watch = JSONOperationStore(url: directory.appendingPathComponent("watch.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor OperationGate {
    private var reached = false
    private var opened = false
    private var paused: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func pause() async {
        reached = true
        arrival?.resume()
        arrival = nil
        if !opened {
            await withCheckedContinuation { paused = $0 }
        }
    }

    func waitUntilPaused() async {
        if !reached {
            await withCheckedContinuation { arrival = $0 }
        }
    }

    func open() {
        opened = true
        paused?.resume()
        paused = nil
    }
}

private actor PausedHTTP: HTTPTransport {
    private let operation: BotOperation
    private let output: HTTPResponse
    private let gate: OperationGate
    private(set) var requests: [BotOperation] = []

    init(_ operation: BotOperation, produces value: some Encodable, gate: OperationGate) throws {
        self.operation = operation
        output = try HTTPResponse(statusCode: 200, body: JSONEncoder().encode(value))
        self.gate = gate
    }

    func exchange(_ request: BotRequest) async -> HTTPResponse {
        requests.append(request.operation)
        if request.operation == operation { await gate.pause() }
        return output
    }
}

private actor CacheCleanupCalls {
    private(set) var count = 0

    func record() { count += 1 }
}
