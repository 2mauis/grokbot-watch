import Foundation
import GrokBotWatchCore
import Testing

@Suite struct BotRoutingTests {
    @Test func routesReadsAndWritesByHarness() async throws {
        let http = try TestHTTP([
            response([exampleBot, sandboxBot]), response([RemoteEntry]()), response([RemoteEntry]()),
            response(DeliveryStatus.accepted), response(DeliveryStatus.accepted),
        ])
        let client = BotClient(transport: http)
        #expect(try await client.listBots() == [exampleBot, sandboxBot])
        _ = try await client.transcript(for: exampleBot)
        _ = try await client.transcript(for: sandboxBot)
        let outbox = Outbox(client: client, wait: { _ in })
        _ = await outbox.write(messageAttempt(), for: exampleBot)
        _ = await outbox.write(messageAttempt(bot: sandboxBot), for: sandboxBot)

        let requests = await http.requests
        #expect(requests.map(\.route) == [
            .gateway("list"), .server("ListGrokBotTranscriptEntries"), .gateway("transcript"),
            .server("SendGrokBotUserMessage"), .gateway("send"),
        ])
        #expect(requests.allSatisfy { $0.timeout == .seconds(30) && $0.responseLimit == 1_048_576 && !$0.followsRedirects })
    }

    @Test func rejectsMismatchedBotWithoutMakingARequest() async throws {
        let http = TestHTTP()
        let output = await Outbox(client: BotClient(transport: http)).write(messageAttempt(), for: sandboxBot)
        #expect(output.status == .rejected)
        #expect(await http.requests.isEmpty)
    }

    @Test func retryOnceOnReadTimeout() async throws {
        let http = try TestHTTP([.failure(.timeout), response([RemoteEntry]())])
        _ = try await BotClient(transport: http).transcript(for: exampleBot)
        #expect(await http.requests.map(\.operation) == [.transcript, .transcript])
    }
}

@Suite struct ProtocolGuardTests {
    @Test(arguments: [401, 403, 404, 426])
    func reportsProtocolFailureForGuardedStatus(_ status: Int) async {
        let http = TestHTTP([rawResponse("{}", status: status)])
        await #expect(throws: BotClientError.degraded(.transcript)) {
            try await BotClient(transport: http).transcript(for: exampleBot)
        }
    }

    @Test(arguments: [
        "[{\"id\":\"bot-1\",\"harness\":\"server\"}]",
        "[{\"id\":42,\"harness\":\"server\",\"isPrimary\":true}]",
        "[{\"id\":\"bot-1\",\"harness\":\"other\",\"isPrimary\":true}]",
    ])
    func rejectsInvalidResponseWithoutGuessing(_ body: String) async {
        let http = TestHTTP([rawResponse(body)])
        await #expect(throws: BotClientError.degraded(.list)) { try await BotClient(transport: http).listBots() }
        #expect(await http.requests.count == 1)
    }
}

@Suite struct OutboxTests {
    @Test func uncertainWritesNeverAutomaticallySendAgain() async throws {
        for uncertainty in [TestHTTP.Step.failure(.timeout), .failure(.disconnected), rawResponse("{}", status: 503), rawResponse("{}", status: 401)] {
            let http = try TestHTTP([uncertainty, response(DeliveryStatus.accepted)])
            let phone = try relay(transport: http, store: TestStore<RelayRecord>())
            let outcome = try await phone.receive(messageAttempt(), for: exampleBot)
            #expect(outcome?.result == .accepted)
            #expect(await http.requests.map(\.operation) == [.send, .getSendStatus])
            _ = try await phone.recoverPending()
            #expect(await http.requests.filter { $0.operation.isWrite }.count == 1)
        }
    }
}

@Suite struct MessageReconcileTests {
    @Test func serverPollsReadStatusWithSameNonceUntilAccepted() async throws {
        let http = try TestHTTP([response(DeliveryStatus.unknown), response(DeliveryStatus.accepted)])
        let outbox = Outbox(client: BotClient(transport: http), wait: { delay in #expect(delay == .seconds(2)) })
        #expect(await outbox.reconcile(messageAttempt(), for: exampleBot).status == .accepted)
        #expect(await http.requests.map(\.operation) == [.getSendStatus, .getSendStatus])
        #expect(await http.requests.allSatisfy { $0.nonce == messageAttempt().nonce })
    }

    @Test func gatewayMatchesUserTextAndNonce() async throws {
        let attempt = messageAttempt(bot: sandboxBot)
        let matching = RemoteEntry(id: "msg-1", role: .user, text: exampleText, nonce: attempt.nonce)
        let differentText = RemoteEntry(id: "msg-2", role: .user, text: "Different reply", nonce: attempt.nonce)
        let differentRole = RemoteEntry(id: "msg-3", role: .bot, text: exampleText, nonce: attempt.nonce)
        let http = try TestHTTP([response([differentText, differentRole]), response([matching])])
        let outbox = Outbox(client: BotClient(transport: http), wait: { _ in })
        #expect(await outbox.reconcile(attempt, for: sandboxBot).status == .notDelivered)
        #expect(await outbox.reconcile(attempt, for: sandboxBot).status == .accepted)
        #expect(await http.requests.map(\.operation) == [.transcript, .transcript])
    }
}

@Suite struct EntryStateGuardTests {
    private var approval: WriteAttempt {
        WriteAttempt(opID: exampleID, number: 1, payload: .approval(botID: exampleBot.id, approvalID: "approval-1", decision: .allow))
    }

    private func entry(_ resolution: EntryResolution) -> RemoteEntry {
        RemoteEntry(id: "approval-1", role: .bot, resolution: resolution)
    }

    @Test func onlyPendingEntriesMayBeWritten() async throws {
        for (resolution, expected) in [(EntryResolution.approvalResolved(.allow), DeliveryStatus.accepted), (.expired, .rejected), (.pending, .accepted)] {
            let http = try TestHTTP([response([entry(resolution)]), response(DeliveryStatus.accepted)])
            let phone = try relay(transport: http, store: TestStore<RelayRecord>())
            #expect(try await phone.receive(approval, for: exampleBot)?.result == expected)
            #expect(await http.requests.map(\.operation) == (resolution == .pending ? [.transcript, .resolveApproval] : [.transcript]))
            #expect(await http.requests.allSatisfy { $0.nonce == nil })
        }
    }

    @Test func timeoutRechecksPendingWithConfiguredDelay() async throws {
        let http = try TestHTTP([response([entry(.pending)]), .failure(.timeout), response([entry(.pending)])])
        let phone = try PhoneRelay(
            store: TestStore<RelayRecord>(),
            outbox: Outbox(client: BotClient(transport: http), confirmationReadDelay: .seconds(3), wait: { delay in #expect(delay == .seconds(3)) }),
            channel: TestWC(),
            now: { exampleTime }
        )
        #expect(try await phone.receive(approval, for: exampleBot)?.result == .notDelivered)
        #expect(await http.requests.map(\.operation) == [.transcript, .resolveApproval, .transcript])
    }

    @Test func missingEntryIsUncertainAndRemainsReadOnlyOnRecovery() async throws {
        let http = try TestHTTP([response([entry(.pending)]), .failure(.timeout), response([RemoteEntry]()), response([entry(.approvalResolved(.allow))])])
        let phone = try relay(transport: http, store: TestStore<RelayRecord>())
        #expect(try await phone.receive(approval, for: exampleBot)?.result == .unknown)
        #expect(try await phone.recoverPending().map(\.result) == [.accepted])
        #expect(await http.requests.map(\.operation) == [.transcript, .resolveApproval, .transcript, .transcript])
    }
}
