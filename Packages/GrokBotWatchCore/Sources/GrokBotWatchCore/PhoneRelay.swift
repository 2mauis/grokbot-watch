import Foundation

public struct RelayRecord: Codable, Equatable, Sendable {
    public let attempt: WriteAttempt
    public let bot: Bot
    public let admittedAt: Int64
    public fileprivate(set) var result: OperationResult?

    public init(attempt: WriteAttempt, bot: Bot, admittedAt: Int64) {
        self.attempt = attempt
        self.bot = bot
        self.admittedAt = admittedAt
    }
}

public actor PhoneRelay {
    private struct EntryKey: Hashable {
        let botID: String
        let entryID: String
    }

    static let retentionMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1_000

    private let store: any OperationStore<RelayRecord>
    private let outbox: Outbox
    private let channel: any WCChannel
    private let now: @Sendable () -> Int64
    private var records: [AttemptKey: RelayRecord] = [:]
    private var resultsWithoutAdmission: [OperationResult] = []
    private var activeOps: Set<UUID> = []
    private var activeEntries: Set<EntryKey> = []
    private var generation: UInt64 = 0
    private var pendingPublications = 0
    private var purgeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: some OperationStore<RelayRecord>, outbox: Outbox, channel: some WCChannel,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws {
        self.store = store
        self.outbox = outbox
        self.channel = channel
        self.now = now
        for record in try store.load() {
            if records.updateValue(record, forKey: record.attempt.key) != nil {
                throw OperationStoreError.duplicateRecord
            }
        }
    }

    /// Clear the local cache at sign-out and wait only for channel calls already dispatched.
    /// Operations suspended on a network response lose their generation immediately.
    public func purge() async throws {
        if !purgeWaiters.isEmpty {
            await withCheckedContinuation { purgeWaiters.append($0) }
            return
        }
        try store.save([])
        generation &+= 1
        records.removeAll()
        resultsWithoutAdmission.removeAll()
        activeOps.removeAll()
        activeEntries.removeAll()

        if pendingPublications > 0 {
            await withCheckedContinuation { purgeWaiters.append($0) }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation && purgeWaiters.isEmpty
    }

    public func receiveMessage(
        _ data: Data, resolveBot: @Sendable (String) async -> Bot?, reply: @Sendable (Data) -> Void
    ) async throws {
        let generation = self.generation
        guard isCurrent(generation) else { return }
        let envelope: WCEnvelope
        do {
            envelope = try EnvelopeCodec.decode(data)
        } catch EnvelopeCodecError.unsupportedVersion {
            let response = WCEnvelope(message: .versionError(supportedVersion: EnvelopeCodec.version), sentAt: now())
            reply(try EnvelopeCodec.encode(response))
            return
        }

        guard case let .write(attempt) = envelope.message else { throw EnvelopeCodecError.invalidEnvelope }
        try pruneExpired()
        let bot: Bot
        if let stored = records[attempt.key] {
            guard stored.attempt == attempt else { return }
            bot = stored.bot
        } else {
            let resolved = await resolveBot(attempt.payload.botID)
            guard isCurrent(generation) else { return }
            guard let resolved else {
                _ = try await report(.init(.rejected, reason: .invalidOperation), for: attempt, writesDone: 0, generation: generation)
                return
            }
            bot = resolved
        }
        let clock = now
        try await receive(attempt, for: bot, generation: generation) { ack in
            if let data = try? EnvelopeCodec.encode(WCEnvelope(message: .ack(ack), sentAt: clock())) {
                reply(data)
            }
        }
    }

    /// Feed the user's write envelope here. Results are queued independently of the immediate ack.
    @discardableResult
    public func receive(
        _ attempt: WriteAttempt, for bot: Bot,
        acknowledge: @Sendable (OperationAck) -> Void = { _ in }
    ) async throws -> OperationResult? {
        try await receive(attempt, for: bot, generation: generation, acknowledge: acknowledge)
    }

    @discardableResult
    private func receive(
        _ attempt: WriteAttempt, for bot: Bot, generation: UInt64,
        acknowledge: @Sendable (OperationAck) -> Void
    ) async throws -> OperationResult? {
        guard isCurrent(generation) else { return nil }
        try pruneExpired()
        let history = records.values.filter { $0.attempt.opID == attempt.opID }
        let count = history.count
        if let existing = records[attempt.key], !matches(existing, attempt: attempt, bot: bot) {
            // A conflicting delivery must not alter the result of the persisted attempt.
            return nil
        }
        guard attempt.payload.botID == bot.id, attempt.payload.isValid else {
            return try await report(.init(.rejected, reason: .invalidOperation), for: attempt, writesDone: count, generation: generation)
        }
        guard (1...WriteAttempt.limit).contains(attempt.number) else {
            return try await report(.init(.rejected, reason: .attempt), for: attempt, writesDone: count, generation: generation)
        }
        if let existing = records[attempt.key] {
            acknowledge(OperationAck(opID: attempt.opID, attempt: attempt.number))
            if let result = existing.result, result.result.isTerminal {
                guard try await publish(.result(result), generation: generation) else { return nil }
                return result
            }
            if activeOps.contains(attempt.opID) { return existing.result }
            return try await reconcile(existing, generation: generation)
        }

        guard attempt.number == count + 1 else {
            return try await report(.init(.rejected, reason: .attempt), for: attempt, writesDone: count, generation: generation)
        }
        guard activeOps.insert(attempt.opID).inserted else { return nil }
        defer { if isCurrent(generation) { activeOps.remove(attempt.opID) } }

        if attempt.number > 1 {
            let previousKey = AttemptKey(opID: attempt.opID, attempt: attempt.number - 1)
            guard let previous = records[previousKey], matches(previous, attempt: attempt, bot: bot) else {
                return try await report(.init(.rejected, reason: .attempt), for: attempt, writesDone: count, generation: generation)
            }
            switch previous.result?.result {
            case .accepted:
                return try await report(.init(.accepted), for: attempt, writesDone: count, generation: generation)
            case .notDelivered:
                break
            default:
                return try await report(.init(.rejected, reason: .attempt), for: attempt, writesDone: count, generation: generation)
            }
        }

        let entry = entryKey(for: attempt)
        if let entry {
            guard !activeEntries.contains(entry),
                  !records.values.contains(where: {
                      $0.attempt.opID != attempt.opID && entryKey(for: $0.attempt) == entry &&
                          $0.result?.result.isTerminal != true
                  })
            else {
                return try await report(.init(.rejected, reason: .inProgress), for: attempt, writesDone: count, generation: generation)
            }
            activeEntries.insert(entry)
        }
        defer { if isCurrent(generation), let entry { activeEntries.remove(entry) } }

        let preflight = await outbox.preflight(attempt, for: bot)
        guard isCurrent(generation) else { return nil }
        if let preflight {
            return try await report(preflight, for: attempt, writesDone: count, generation: generation)
        }
        try Task.checkCancellation()
        let record = RelayRecord(attempt: attempt, bot: bot, admittedAt: now())
        do {
            try save(record)
        } catch {
            return try await report(.init(.rejected, reason: .storage), for: attempt, writesDone: count, generation: generation)
        }

        resultsWithoutAdmission.removeAll { $0.key == attempt.key }
        acknowledge(OperationAck(opID: attempt.opID, attempt: attempt.number))
        let outcome = await outbox.write(attempt, for: bot)
        return try await finish(outcome, for: record, generation: generation)
    }

    @discardableResult
    public func recoverPending() async throws -> [OperationResult] {
        let generation = self.generation
        guard isCurrent(generation) else { return [] }
        try pruneExpired()
        let pending = records.values.filter { $0.result?.result.isTerminal != true }
        var recovered: [OperationResult] = []
        for record in pending {
            // Another recovery can finish this entry while the previous network read suspends.
            guard let current = records[record.attempt.key], current.result?.result.isTerminal != true else { continue }
            let result = try await reconcile(current, generation: generation)
            guard isCurrent(generation) else { return [] }
            if let result { recovered.append(result) }
        }
        return recovered
    }

    public func recentResults() -> [OperationResult] {
        let stored = records.values.compactMap(\.result)
        return Array((stored + resultsWithoutAdmission).sorted {
            if $0.finishedAt != $1.finishedAt { return $0.finishedAt > $1.finishedAt }
            if $0.opID != $1.opID { return $0.opID.uuidString < $1.opID.uuidString }
            return $0.attempt > $1.attempt
        }.prefix(20))
    }

    public func publishSnapshot(_ snapshot: InboxSnapshot) async throws {
        let generation = self.generation
        guard isCurrent(generation) else { return }
        try pruneExpired()
        var updated = snapshot
        updated.recentOps = recentResults()
        _ = try await publish(.snapshot(updated), generation: generation)
    }

    private func reconcile(_ record: RelayRecord, generation: UInt64) async throws -> OperationResult? {
        guard isCurrent(generation) else { return nil }
        let id = record.attempt.opID
        guard activeOps.insert(id).inserted else { return record.result }
        defer { if isCurrent(generation) { activeOps.remove(id) } }
        let outcome = await outbox.reconcile(record.attempt, for: record.bot)
        return try await finish(outcome, for: record, generation: generation)
    }

    private func finish(_ outcome: WriteOutcome, for admitted: RelayRecord, generation: UInt64) async throws -> OperationResult? {
        guard isCurrent(generation) else { return nil }
        let attempt = admitted.attempt
        let result = makeResult(outcome, for: attempt, writesDone: attempt.number)
        if result.advances(admitted.result) {
            var updated = admitted
            updated.result = result
            try save(updated)
        }
        let persisted = records[attempt.key]?.result ?? result
        guard try await publish(.result(persisted), generation: generation) else { return nil }
        return persisted
    }

    private func report(
        _ outcome: WriteOutcome, for attempt: WriteAttempt, writesDone: Int, generation: UInt64
    ) async throws -> OperationResult? {
        guard isCurrent(generation) else { return nil }
        let result = makeResult(outcome, for: attempt, writesDone: writesDone)
        // Preflight and storage failures have no admitted record but still go into the next snapshot.
        resultsWithoutAdmission.removeAll { $0.key == result.key }
        resultsWithoutAdmission.insert(result, at: 0)
        if resultsWithoutAdmission.count > 20 { resultsWithoutAdmission.removeLast() }
        guard try await publish(.result(result), generation: generation) else { return nil }
        return result
    }

    private func makeResult(_ outcome: WriteOutcome, for attempt: WriteAttempt, writesDone: Int) -> OperationResult {
        OperationResult(
            opID: attempt.opID, attempt: attempt.number, writesDone: writesDone, result: outcome.status,
            reason: outcome.reason, finishedAt: now()
        )
    }

    private func publish(_ message: WCMessage, generation: UInt64) async throws -> Bool {
        guard isCurrent(generation) else { return false }
        let encoded = try EnvelopeCodec.encode(WCEnvelope(message: message, sentAt: now()))
        pendingPublications += 1
        defer {
            pendingPublications -= 1
            if pendingPublications == 0 {
                let waiters = purgeWaiters
                purgeWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        do {
            if case .snapshot = message {
                try await channel.updateApplicationContext(encoded)
            } else {
                try await channel.transferUserInfo(encoded)
            }
        } catch {
            guard isCurrent(generation) else { return false }
            throw error
        }
        return isCurrent(generation)
    }

    private func save(_ record: RelayRecord) throws {
        var next = records
        next[record.attempt.key] = record
        try store.save(Array(next.values))
        records = next
    }

    private func pruneExpired() throws {
        let cutoff = now() - Self.retentionMilliseconds
        let liveIDs = Set(records.values.compactMap {
            $0.admittedAt > cutoff ? $0.attempt.opID : nil
        }).union(activeOps)
        let next = records.filter { liveIDs.contains($0.key.opID) }
        if next.count != records.count {
            try store.save(Array(next.values))
            records = next
        }
    }

    private func entryKey(for attempt: WriteAttempt) -> EntryKey? {
        attempt.payload.entryID.map { EntryKey(botID: attempt.payload.botID, entryID: $0) }
    }

    private func matches(_ record: RelayRecord, attempt: WriteAttempt, bot: Bot) -> Bool {
        record.attempt.payload == attempt.payload && record.bot.id == bot.id && record.bot.harness == bot.harness
    }
}
