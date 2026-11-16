import Foundation

public struct WriteOutcome: Equatable, Sendable {
    public let status: DeliveryStatus
    public let reason: ResultReason?

    init(_ status: DeliveryStatus, reason: ResultReason? = nil) {
        self.status = status
        self.reason = reason
    }
}

public struct Outbox: Sendable {
    // Provisional settling delay. Tune after observing confirmation reads on a device.
    public static let defaultConfirmationReadDelay: Duration = .seconds(1)

    private let client: BotClient
    private let confirmationReadDelay: Duration
    private let wait: @Sendable (Duration) async throws -> Void

    public init(
        client: BotClient, confirmationReadDelay: Duration = Self.defaultConfirmationReadDelay,
        wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.confirmationReadDelay = max(.zero, confirmationReadDelay)
        self.wait = wait
    }

    // A nil result means the entry is still pending and the relay may admit a write.
    func preflight(_ attempt: WriteAttempt, for bot: Bot) async -> WriteOutcome? {
        guard let entryID = attempt.payload.entryID else { return nil }
        do {
            guard let resolution = try await entryState(entryID, for: bot) else {
                return WriteOutcome(.rejected, reason: .protocolFailure)
            }
            if resolution == .pending { return nil }
            return EntryStateGuard.outcome(for: resolution, matching: attempt.payload)
        } catch {
            return WriteOutcome(.rejected, reason: .protocolFailure)
        }
    }

    // Only PhoneRelay calls this, after saving the attempt and acknowledging it.
    func write(_ attempt: WriteAttempt, for bot: Bot) async -> WriteOutcome {
        do {
            let status = try await client.write(attempt, for: bot)
            if status.isTerminal, status != .notDelivered || attempt.payload.entryID == nil {
                return WriteOutcome(status)
            }
        } catch BotClientError.invalidOperation {
            return WriteOutcome(.rejected, reason: .invalidOperation)
        } catch is CancellationError {
            return WriteOutcome(.unknown)
        } catch BotClientError.degraded {
            let outcome = await reconcile(attempt, for: bot)
            if outcome.status == .unknown { return WriteOutcome(.unknown, reason: .protocolFailure) }
            return outcome
        } catch {
            // An interrupted exchange may have reached the service.
        }
        return await reconcile(attempt, for: bot)
    }

    public func reconcile(_ attempt: WriteAttempt, for bot: Bot) async -> WriteOutcome {
        guard attempt.payload.isValid, attempt.payload.botID == bot.id else {
            return WriteOutcome(.rejected, reason: .invalidOperation)
        }
        if let entryID = attempt.payload.entryID {
            do {
                try await wait(confirmationReadDelay)
                guard let resolution = try await entryState(entryID, for: bot) else {
                    return WriteOutcome(.unknown)
                }
                return EntryStateGuard.outcome(for: resolution, matching: attempt.payload)
            } catch BotClientError.degraded {
                return WriteOutcome(.unknown, reason: .protocolFailure)
            } catch {
                return WriteOutcome(.unknown)
            }
        }

        guard case let .message(_, text, _) = attempt.payload, let nonce = attempt.nonce else {
            return WriteOutcome(.rejected, reason: .invalidOperation)
        }
        if bot.harness == .gateway {
            return await reconcileGatewayMessage(bot, nonce: nonce, text: text)
        }
        return await reconcileServerMessage(bot, nonce: nonce)
    }

    private func entryState(_ id: String, for bot: Bot) async throws -> EntryResolution? {
        let matches = try await client.transcript(for: bot).filter { $0.id == id }
        guard matches.count <= 1 else { throw BotClientError.degraded(.transcript) }
        return matches.first?.resolution
    }

    private func reconcileGatewayMessage(_ bot: Bot, nonce: String, text: String) async -> WriteOutcome {
        do {
            let entries = try await client.transcript(for: bot)
            let delivered = entries.contains { $0.role == .user && $0.nonce == nonce && $0.text == text }
            return WriteOutcome(delivered ? .accepted : .notDelivered)
        } catch BotClientError.degraded {
            return WriteOutcome(.unknown, reason: .protocolFailure)
        } catch {
            return WriteOutcome(.unknown)
        }
    }

    private func reconcileServerMessage(_ bot: Bot, nonce: String) async -> WriteOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(60)
        for check in 0..<30 {
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero { break }
            do {
                let status = try await client.sendStatus(for: bot, nonce: nonce, timeout: min(remaining, .seconds(5)))
                if status.isTerminal { return WriteOutcome(status) }
            } catch BotClientError.degraded {
                return WriteOutcome(.unknown, reason: .protocolFailure)
            } catch is CancellationError {
                return WriteOutcome(.unknown)
            } catch {
                // Keep polling with read requests until the deadline.
            }
            if check == 29 { break }
            do {
                try await wait(min(.seconds(2), max(.zero, clock.now.duration(to: deadline))))
            } catch {
                return WriteOutcome(.unknown)
            }
        }
        return WriteOutcome(Task.isCancelled ? .unknown : .notDelivered)
    }
}

enum EntryStateGuard {
    static func outcome(for resolution: EntryResolution, matching payload: WritePayload) -> WriteOutcome {
        switch (resolution, payload) {
        case (.pending, _):
            return WriteOutcome(.notDelivered)
        case (.expired, _):
            return WriteOutcome(.rejected, reason: .expired)
        case let (.widgetAnswered(actual), .widget(_, _, .answer(expected))):
            return compare(actual == expected)
        case let (.approvalResolved(actual), .approval(_, _, expected)):
            return compare(actual == expected)
        case let (.formSubmitted(actual), .form(_, _, .submit(expected))):
            return compare(actual == nil || actual == expected)
        case (.widgetDismissed, .widget(_, _, .dismiss)), (.formDismissed, .form(_, _, .dismiss)):
            return WriteOutcome(.accepted)
        default:
            return WriteOutcome(.rejected, reason: .alreadyHandled)
        }
    }

    private static func compare(_ sameAnswer: Bool) -> WriteOutcome {
        sameAnswer ? WriteOutcome(.accepted) : WriteOutcome(.rejected, reason: .alreadyHandled)
    }
}
