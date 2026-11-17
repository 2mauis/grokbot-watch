import Foundation
import GrokBotWatchCore
import Testing

@Suite struct RelayIdempotencyTests {
    @Test func lostAcknowledgmentRedeliveryRequeuesResultWithoutAnotherWrite() async throws {
        let http = try TestHTTP([response(DeliveryStatus.accepted)])
        let wc = TestWC()
        let phone = try relay(transport: http, store: TestStore<RelayRecord>(), wc: wc)
        let first = try await phone.receive(messageAttempt(), for: exampleBot)
        let second = try await phone.receive(messageAttempt(), for: exampleBot)
        #expect(first == result(.accepted))
        #expect(second == first)
        #expect(await http.requests.map(\.operation) == [.send])
        #expect(await wc.results.count == 2)
    }

    @Test func restartAfterWriteReconcilesOnly() async throws {
        let pending = RelayRecord(attempt: messageAttempt(), bot: exampleBot, admittedAt: exampleTime)
        let http = try TestHTTP([response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: TestStore([pending]))

        #expect(try await phone.receive(messageAttempt(), for: exampleBot) == result(.accepted))
        #expect(await http.requests.map(\.operation) == [.getSendStatus])
    }

    @Test func concurrentDuplicateExecutesOneWriteAndAcknowledgesAfterPersistence() async throws {
        let store = TestStore<RelayRecord>()
        let http = try TestHTTP([response(DeliveryStatus.accepted)]) { request in
            if request.operation == .send {
                #expect(store.load().first?.attempt == messageAttempt())
                #expect(store.load().first?.result == nil)
            }
        }
        let phone = try relay(transport: http, store: store)

        async let first = phone.receive(messageAttempt(), for: exampleBot, acknowledge: { ack in
            #expect(ack.persisted)
            #expect(store.load().first?.attempt == messageAttempt())
        })
        async let second = phone.receive(messageAttempt(), for: exampleBot)
        _ = try await (first, second)
        #expect(await http.requests.map(\.operation) == [.send])
    }

    @Test func notDeliveredAdmitsAttemptTwoWithSameNonce() async throws {
        let http = try TestHTTP([.failure(.timeout), response(DeliveryStatus.notDelivered), response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: TestStore<RelayRecord>())

        #expect(try await phone.receive(messageAttempt(), for: exampleBot) == result(.notDelivered))
        #expect(try await phone.receive(messageAttempt(2), for: exampleBot) == result(.accepted, 2))
        let writes = await http.requests.filter { $0.operation == .send }
        #expect(writes.count == 2)
        #expect(writes.map(\.nonce) == [messageAttempt().nonce, messageAttempt().nonce])
    }

    @Test func acceptedAttemptReturnsAcceptedWithoutAnotherWrite() async throws {
        let http = try TestHTTP([response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: TestStore<RelayRecord>())
        _ = try await phone.receive(messageAttempt(), for: exampleBot)
        let retry = try await phone.receive(messageAttempt(2), for: exampleBot)
        #expect(retry?.result == .accepted)
        #expect(retry?.writesDone == 1)
        #expect(await http.requests.map(\.operation) == [.send])
    }

    @Test func rejectsSkippingAnAttempt() async throws {
        let http = try TestHTTP([response(DeliveryStatus.notDelivered)])
        let phone = try relay(transport: http, store: TestStore<RelayRecord>())
        _ = try await phone.receive(messageAttempt(), for: exampleBot)
        let skipped = try await phone.receive(messageAttempt(3), for: exampleBot)
        #expect(skipped?.result == .rejected)
        #expect(skipped?.reason == .attempt)
        #expect(await http.requests.map(\.operation) == [.send])
    }

    @Test func rejectsFourthAttempt() async throws {
        let http = try TestHTTP([
            response(DeliveryStatus.notDelivered), response(DeliveryStatus.notDelivered), response(DeliveryStatus.notDelivered),
        ])
        let phone = try relay(transport: http, store: TestStore<RelayRecord>())
        for number in 1...3 {
            _ = try await phone.receive(messageAttempt(number), for: exampleBot)
        }
        let fourth = try await phone.receive(messageAttempt(4), for: exampleBot)
        #expect(fourth?.result == .rejected)
        #expect(fourth?.reason == .attempt)
        #expect(fourth?.writesDone == 3)
        #expect(await http.requests.map(\.operation) == [.send, .send, .send])
    }

    @Test func restartBeforeNetworkWriteStillCountsPersistedAttempt() async throws {
        let pending = RelayRecord(attempt: messageAttempt(), bot: exampleBot, admittedAt: exampleTime)
        let http = try TestHTTP([response(DeliveryStatus.notDelivered), response(DeliveryStatus.accepted)])
        let phone = try relay(transport: http, store: TestStore([pending]))

        let recovered = try await phone.recoverPending()
        #expect(recovered == [result(.notDelivered)])
        #expect(try await phone.receive(messageAttempt(2), for: exampleBot) == result(.accepted, 2))
        #expect(await http.requests.map(\.operation) == [.getSendStatus, .send])
    }

    @Test func storageFailurePreventsAckAndWrite() async throws {
        let http = TestHTTP()
        let phone = try relay(transport: http, store: TestStore<RelayRecord>(rejectsSaves: true))
        let output = try await phone.receive(messageAttempt(), for: exampleBot, acknowledge: { _ in
            Issue.record("Acknowledged an operation that was not stored")
        })
        #expect(output?.reason == .storage)
        #expect(output?.writesDone == 0)
        let rejected = try #require(output)
        #expect(await phone.recentResults() == [rejected])
        #expect(await http.requests.isEmpty)
    }

    @Test func retryCannotChangeTheOriginalText() async throws {
        let http = try TestHTTP([response(DeliveryStatus.notDelivered)])
        let phone = try relay(transport: http, store: TestStore<RelayRecord>())
        _ = try await phone.receive(messageAttempt(), for: exampleBot)
        let changed = WriteAttempt(opID: exampleID, number: 2, payload: .message(botID: exampleBot.id, text: "Different reply", source: .suggestion))
        #expect(try await phone.receive(changed, for: exampleBot)?.reason == .attempt)
        #expect(await http.requests.map(\.operation) == [.send])
    }
}

@Suite struct NonceDerivationTests {
    @Test func nonceIsLowercaseAndIgnoresAttempt() {
        #expect(messageAttempt().nonce == "c05944d2-25ba-45ff-8ba6-112233445566")
        #expect(messageAttempt(3).nonce == messageAttempt().nonce)
    }

    @Test func confirmationHasNoNonce() {
        let item = WriteAttempt(opID: exampleID, number: 1, payload: .approval(botID: exampleBot.id, approvalID: "approval-1", decision: .allow))
        #expect(item.nonce == nil)
    }
}

@Suite struct WatchOutboxTests {
    @Test func persistsBeforeDeliveryAndKeepsIdentityForRedelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONOperationStore<WatchRecord>(url: directory.appendingPathComponent("outbox.json"))
        let original = try WatchOutbox(store: store)
        _ = try await original.enqueue(messageAttempt().payload, opID: exampleID)
        #expect(try store.load().first?.state == .queued)
        let offline = TestWC(acknowledge: false) {
            #expect((try? store.load().first?.state) == .sentNoAck)
        }
        await #expect(throws: TestFailure.disconnected) { try await original.deliver(exampleID, through: offline) }
        let reopened = try WatchOutbox(store: store)
        #expect(await reopened.record(for: exampleID)?.state == .sentNoAck)
        let online = TestWC()
        try await reopened.deliver(exampleID, through: online)
        let offlineData = try #require(await offline.messages.first)
        let onlineData = try #require(await online.messages.first)
        let first = try EnvelopeCodec.decode(offlineData)
        let second = try EnvelopeCodec.decode(onlineData)
        #expect(first.id != second.id)
        #expect(first.message == WCMessage.write(messageAttempt()))
        #expect(second.message == first.message)
        #expect(await reopened.record(for: exampleID)?.state == .handedToPhone)
    }

    @Test func retryRequiresNotDeliveredAndPreservesPayload() async throws {
        let watch = try WatchOutbox(store: TestStore<WatchRecord>())
        _ = try await watch.enqueue(messageAttempt().payload, opID: exampleID)
        try await watch.apply(result(.unknown))
        await #expect(throws: WatchOutboxError.retryUnavailable) { try await watch.retry(exampleID) }
        try await watch.apply(result(.notDelivered))
        #expect(try await watch.retry(exampleID) == messageAttempt(2))
        #expect(await watch.record(for: exampleID)?.state == .queued)
    }
}

@Suite struct ResultDeliveryTests {
    @Test func persistedResultIsAvailableInBothDeliveryChannels() async throws {
        let http = try TestHTTP([response(DeliveryStatus.accepted)])
        let store = TestStore<RelayRecord>()
        let channel = TestWC()
        let phone = try relay(transport: http, store: store, wc: channel)
        _ = try await phone.receive(messageAttempt(), for: exampleBot)

        let userInfo = try #require(await channel.results.first)
        #expect(try EnvelopeCodec.decode(userInfo).message == .result(result(.accepted)))
        let reopened = try relay(transport: http, store: store, wc: channel)
        try await reopened.publishSnapshot(InboxSnapshot(generatedAt: exampleTime))
        let context = try #require(await channel.snapshot)
        #expect(try EnvelopeCodec.decode(context).message == .snapshot(InboxSnapshot(recentOps: [result(.accepted)], generatedAt: exampleTime)))
    }

    @Test func unknownMayAdvanceToAccepted() async throws {
        let watch = try WatchOutbox(store: TestStore<WatchRecord>())
        _ = try await watch.enqueue(messageAttempt().payload, opID: exampleID)
        try await watch.apply(result(.unknown))
        #expect(await watch.record(for: exampleID)?.state == .unknown)
        try await watch.apply(result(.accepted))
        #expect(await watch.record(for: exampleID)?.state == .accepted)
    }

    @Test func olderSnapshotCannotOverwriteUserInfoTerminalResult() async throws {
        let watch = try WatchOutbox(store: TestStore<WatchRecord>())
        _ = try await watch.enqueue(messageAttempt().payload, opID: exampleID)
        try await watch.apply(result(.accepted))
        try await watch.apply(snapshot: InboxSnapshot(recentOps: [result(.unknown), result(.rejected)], generatedAt: 10))
        #expect(await watch.record(for: exampleID)?.state == .accepted)
        #expect(await watch.record(for: exampleID)?.results == [result(.accepted)])
    }

    @Test func lateOldAttemptDoesNotAffectCurrentAttempt() async throws {
        let watch = try WatchOutbox(store: TestStore<WatchRecord>())
        _ = try await watch.enqueue(messageAttempt().payload, opID: exampleID)
        try await watch.apply(result(.notDelivered))
        _ = try await watch.retry(exampleID)
        try await watch.apply(result(.accepted, 2))
        try await watch.apply(result(.unknown))
        #expect(await watch.record(for: exampleID)?.state == .accepted)
        #expect(await watch.record(for: exampleID)?.results == [result(.notDelivered), result(.accepted, 2)])
    }
}
