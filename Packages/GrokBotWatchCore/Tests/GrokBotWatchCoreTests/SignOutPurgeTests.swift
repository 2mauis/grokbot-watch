import Foundation
import GrokBotWatchCore
import Testing

@Suite struct SignOutPurgeTests {
    @Test func signOutClearsBothCachesWithoutRestoringOldEntriesOnNextSave() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let http = try TestHTTP([response(DeliveryStatus.accepted), response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: storage.phone)
        let watch = try WatchOutbox(store: storage.watch)
        let old = try await watch.enqueue(messageAttempt().payload, opID: exampleID)
        _ = try await phone.receive(old, for: exampleBot)
        _ = try await phone.receive(messageAttempt(3), for: exampleBot)

        let credentials = TestTokenStore()
        await credentials.save(SessionToken(access: "sample-access", refresh: "sample-refresh"))
        let nextSession = SessionToken(access: "next-access", refresh: "next-refresh")
        let auth = AuthClient(transport: TestAuth([.authorized(nextSession)]), tokenStore: credentials) {
            try await phone.purge()
            try await watch.purge()
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

        await auth.begin(try PKCE.generate(using: SampleHasher()))
        #expect(try await auth.poll() == .signedIn)
        #expect(await credentials.load() == nextSession)
        let fresh = try await watch.enqueue(messageAttempt().payload)
        _ = try await phone.receive(fresh, for: exampleBot)
        #expect(try storage.watch.load().map(\.attempt) == [fresh])
        #expect(try storage.phone.load().map(\.attempt) == [fresh])
    }

    @Test func signOutDuringWriteDiscardsOldCompletionWithoutSavingOrPublishing() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let gate = OperationGate()
        let http = try PausedHTTP(.send, produces: DeliveryStatus.accepted, gates: [gate])
        let channel = TestWC()
        let phone = try relay(transport: http, store: storage.phone, wc: channel)
        let auth = AuthClient(transport: TestAuth(), tokenStore: TestTokenStore()) {
            try await phone.purge()
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

    @Test func purgeDuringBotResolutionDoesNotAdmitOldMessage() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let gate = OperationGate()
        let http = TestHTTP()
        let channel = TestWC()
        let phone = try relay(transport: http, store: storage.phone, wc: channel)
        let envelope = try EnvelopeCodec.encode(WCEnvelope(message: .write(messageAttempt())))

        let receive = Task {
            try await phone.receiveMessage(envelope, resolveBot: { _ in
                await gate.pause()
                return exampleBot
            }, reply: { _ in Issue.record("Acknowledged a cleared operation") })
        }
        await gate.waitUntilPaused()
        do { try await phone.purge() } catch {
            await gate.open()
            throw error
        }
        await gate.open()
        try await receive.value

        #expect(await http.requests.isEmpty)
        #expect(await channel.results.isEmpty)
        #expect(try storage.phone.load().isEmpty)
    }

    @Test func purgeDuringPreflightPreventsTheWriteAndAcknowledgment() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let gate = OperationGate()
        let pending = RemoteEntry(id: "approval", role: .bot, resolution: .pending)
        let http = try PausedHTTP(.transcript, produces: [pending], gates: [gate])
        let channel = TestWC()
        let phone = try relay(transport: http, store: storage.phone, wc: channel)
        let attempt = WriteAttempt(
            opID: exampleID, number: 1, payload: .approval(botID: exampleBot.id, approvalID: "approval", decision: .allow)
        )

        let receive = Task {
            try await phone.receive(attempt, for: exampleBot) { _ in Issue.record("Acknowledged a cleared operation") }
        }
        await gate.waitUntilPaused()
        do { try await phone.purge() } catch {
            await gate.open()
            throw error
        }
        await gate.open()

        #expect(try await receive.value == nil)
        #expect(await http.requests == [.transcript])
        #expect(await channel.results.isEmpty)
        #expect(try storage.phone.load().isEmpty)
    }

    @Test func purgeDuringRecoveryDiscardsTheOldReadResult() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let gate = OperationGate()
        let http = try PausedHTTP(.getSendStatus, produces: DeliveryStatus.accepted, gates: [gate])
        let channel = TestWC()
        try storage.phone.save([RelayRecord(attempt: messageAttempt(), bot: exampleBot, admittedAt: exampleTime)])
        let phone = try relay(transport: http, store: storage.phone, wc: channel)

        let recovery = Task { try await phone.recoverPending() }
        await gate.waitUntilPaused()
        do { try await phone.purge() } catch {
            await gate.open()
            throw error
        }
        await gate.open()

        #expect(try await recovery.value.isEmpty)
        #expect(await http.requests == [.getSendStatus])
        #expect(await phone.recentResults().isEmpty)
        #expect(await channel.results.isEmpty)
        #expect(try storage.phone.load().isEmpty)
    }

    @Test func lateWatchAckCannotAcknowledgeOrUnlockTheNewDelivery() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let watch = try WatchOutbox(store: storage.watch)
        let initialGate = OperationGate()
        let freshGate = OperationGate()
        let initialChannel = PausedUserInfo(gate: initialGate, pausesSendMessage: true)
        let freshChannel = PausedUserInfo(gate: freshGate, pausesSendMessage: true)
        let attempt = try await watch.enqueue(messageAttempt().payload, opID: exampleID)

        let old = Task { try await watch.deliver(attempt.opID, through: initialChannel) }
        await initialGate.waitUntilPaused()
        do {
            try await watch.purge()
            #expect(try storage.watch.load().isEmpty)
            _ = try await watch.enqueue(attempt.payload, opID: exampleID)
        } catch {
            await initialGate.open()
            throw error
        }
        let new = Task { try await watch.deliver(attempt.opID, through: freshChannel) }
        await freshGate.waitUntilPaused()
        await initialGate.open()
        do {
            try await old.value
            #expect(await watch.record(for: attempt.opID)?.state == .sentNoAck)
            #expect(try storage.watch.load().first?.state == .sentNoAck)
            await #expect(throws: WatchOutboxError.deliveryUnavailable) {
                try await watch.deliver(attempt.opID, through: TestWC())
            }
        } catch {
            await freshGate.open()
            throw error
        }
        await freshGate.open()
        try await new.value
        #expect(await watch.record(for: attempt.opID)?.state == .handedToPhone)
    }

    @Test func signOutWaitsForPublicationAlreadyHandedToTheChannel() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let gate = OperationGate()
        let channel = PausedUserInfo(gate: gate)
        let http = try TestHTTP([response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: storage.phone, wc: channel)
        let credentials = TestTokenStore()
        await credentials.save(SessionToken(access: "sample-access", refresh: "sample-refresh"))
        let signOutCompletions = CacheCleanupCalls()
        let auth = AuthClient(transport: TestAuth(), tokenStore: credentials) { try await phone.purge() }
        #expect(try await auth.restore() == .signedIn)

        let receive = Task { try await phone.receive(messageAttempt(), for: exampleBot) }
        await gate.waitUntilPaused()
        let signOut = Task {
            try await auth.signOut()
            await signOutCompletions.record()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while (try? storage.phone.load().isEmpty) == false, clock.now < deadline {
            await Task.yield()
        }
        #expect(try storage.phone.load().isEmpty)
        #expect(await phone.recentResults().isEmpty)
        #expect(await signOutCompletions.count == 0)
        #expect(await channel.backing.results.isEmpty)

        await gate.open()
        try await signOut.value
        #expect(try await receive.value == nil)
        #expect(await auth.state == .signedOut)
        #expect(try storage.phone.load().isEmpty)
        #expect(await channel.backing.results.count == 1)
    }

    @Test func failedPurgePreservesMatchingCachesAndBlocksNewLoginUntilRetry() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let phoneStore = FailingClearStore(storage.phone)
        let watchStore = FailingClearStore(storage.watch)
        let http = try TestHTTP([response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: phoneStore)
        let watch = try WatchOutbox(store: watchStore)
        let attempt = try await watch.enqueue(messageAttempt().payload, opID: exampleID)
        _ = try await phone.receive(attempt, for: exampleBot)
        let auth = AuthClient(transport: TestAuth(), tokenStore: TestTokenStore()) {
            try await phone.purge()
            try await watch.purge()
        }

        await #expect(throws: TestFailure.storage) { try await auth.signOut() }
        #expect(try storage.phone.load().map(\.attempt) == [attempt])
        #expect(await phone.recentResults() == [result(.accepted)])
        #expect(try storage.watch.load().map(\.attempt) == [attempt])
        #expect(await watch.record(for: attempt.opID)?.attempt == attempt)

        phoneStore.allowClear()
        await #expect(throws: TestFailure.storage) { try await auth.signOut() }
        #expect(try storage.phone.load().isEmpty)
        #expect(await phone.recentResults().isEmpty)
        #expect(try storage.watch.load().map(\.attempt) == [attempt])
        #expect(await watch.record(for: attempt.opID)?.attempt == attempt)
        let authorization = try PKCE.generate(using: SampleHasher())
        await auth.begin(authorization)
        #expect(await auth.state == .needsLogin)

        watchStore.allowClear()
        try await auth.signOut()
        #expect(try storage.watch.load().isEmpty)
        #expect(await watch.record(for: attempt.opID) == nil)
        #expect(await auth.state == .signedOut)
        await auth.begin(authorization)
        #expect(await auth.state == .awaitingAuthorization)
    }

    @Test func newSessionRetainsItsReservationAcross64ConcurrentRedeliveries() async throws {
        let storage = try LocalOperationStores()
        defer { storage.remove() }
        let oldGate = OperationGate()
        let newGate = OperationGate()
        let http = try PausedHTTP(.send, produces: DeliveryStatus.accepted, gates: [oldGate, newGate])
        let channel = TestWC()
        let phone = try relay(transport: http, store: storage.phone, wc: channel)
        let auth = AuthClient(transport: TestAuth(), tokenStore: TestTokenStore()) { try await phone.purge() }

        let old = Task { try await phone.receive(messageAttempt(), for: exampleBot) }
        await oldGate.waitUntilPaused()
        do { try await auth.signOut() } catch {
            await oldGate.open()
            throw error
        }
        let new = Task { try await phone.receive(messageAttempt(), for: exampleBot) }
        await newGate.waitUntilPaused()
        await oldGate.open()
        do {
            #expect(try await old.value == nil)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<64 {
                    group.addTask {
                        let duplicate = try await phone.receive(messageAttempt(), for: exampleBot)
                        #expect(duplicate == nil)
                    }
                }
                try await group.waitForAll()
            }
            #expect(try storage.phone.load().first?.result == nil)
            #expect(await channel.results.isEmpty)
        } catch {
            await newGate.open()
            throw error
        }
        await newGate.open()

        #expect(try await new.value == result(.accepted))
        #expect(await http.requests == [.send, .send])
        #expect(await channel.results.count == 1)
        #expect(try storage.phone.load().first?.result == result(.accepted))
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
    private var gates: [OperationGate]
    private(set) var requests: [BotOperation] = []

    init(_ operation: BotOperation, produces value: some Encodable, gates: [OperationGate]) throws {
        self.operation = operation
        output = try HTTPResponse(statusCode: 200, body: JSONEncoder().encode(value))
        self.gates = gates
    }

    func exchange(_ request: BotRequest) async -> HTTPResponse {
        requests.append(request.operation)
        if request.operation == operation, !gates.isEmpty { await gates.removeFirst().pause() }
        return output
    }
}

private actor CacheCleanupCalls {
    private(set) var count = 0

    func record() { count += 1 }
}

private struct PausedUserInfo: WCChannel {
    let gate: OperationGate
    var pausesSendMessage = false
    let backing = TestWC()

    func sendMessage(_ data: Data) async throws -> Data {
        if pausesSendMessage { await gate.pause() }
        return try await backing.sendMessage(data)
    }

    func transferUserInfo(_ data: Data) async {
        if !pausesSendMessage { await gate.pause() }
        await backing.transferUserInfo(data)
    }

    func updateApplicationContext(_ data: Data) async {
        await backing.updateApplicationContext(data)
    }
}

private final class FailingClearStore<Record: Codable & Sendable>: OperationStore, @unchecked Sendable {
    private let store: JSONOperationStore<Record>
    private let lock = NSLock()
    private var rejectsEmptySave = true

    init(_ store: JSONOperationStore<Record>) { self.store = store }

    func load() throws -> [Record] { try store.load() }

    func save(_ records: [Record]) throws {
        if records.isEmpty, lock.withLock({ rejectsEmptySave }) { throw TestFailure.storage }
        try store.save(records)
    }

    func allowClear() {
        lock.withLock { rejectsEmptySave = false }
    }
}
