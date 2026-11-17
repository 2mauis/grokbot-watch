import Foundation

public enum WatchOutboxError: Error {
    case unknownOperation
    case invalidOperation
    case deliveryUnavailable
    case retryUnavailable
    case invalidAck
}

public struct WatchRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued
        case sentNoAck
        case handedToPhone
        case accepted
        case rejected
        case notDelivered
        case unknown

        init(_ status: DeliveryStatus) {
            switch status {
            case .accepted: self = .accepted
            case .rejected: self = .rejected
            case .notDelivered: self = .notDelivered
            case .unknown: self = .unknown
            }
        }
    }

    public fileprivate(set) var attempt: WriteAttempt
    public fileprivate(set) var state: State = .queued
    public fileprivate(set) var results: [OperationResult] = []
    public let createdAt: Int64

    fileprivate init(attempt: WriteAttempt, createdAt: Int64) {
        self.attempt = attempt
        self.createdAt = createdAt
    }

    public var canRetry: Bool {
        state == .notDelivered && attempt.number < WriteAttempt.limit
    }
}

public actor WatchOutbox {
    private let store: any OperationStore<WatchRecord>
    private let now: @Sendable () -> Int64
    private var records: [UUID: WatchRecord] = [:]
    private var delivering: Set<UUID> = []
    private var generation: UInt64 = 0

    public init(
        store: some OperationStore<WatchRecord>,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws {
        self.store = store
        self.now = now
        for record in try store.load() {
            if records.updateValue(record, forKey: record.attempt.opID) != nil {
                throw OperationStoreError.duplicateRecord
            }
        }
    }

    /// Clear the local cache at sign-out. A failed save leaves the previous cache intact.
    public func purge() throws {
        try store.save([])
        generation &+= 1
        records.removeAll()
        delivering.removeAll()
    }

    public func record(for opID: UUID) -> WatchRecord? { records[opID] }

    @discardableResult
    public func enqueue(_ payload: WritePayload, opID: UUID = UUID()) throws -> WriteAttempt {
        guard payload.isValid, records[opID] == nil else { throw WatchOutboxError.invalidOperation }
        let attempt = WriteAttempt(opID: opID, number: 1, payload: payload)
        try save(WatchRecord(attempt: attempt, createdAt: now()))
        return attempt
    }

    public func deliver(_ opID: UUID, through channel: some WCChannel) async throws {
        guard var record = records[opID] else { throw WatchOutboxError.unknownOperation }
        guard record.state == .queued || record.state == .sentNoAck,
              isWithinRetention(record), delivering.insert(opID).inserted else {
            throw WatchOutboxError.deliveryUnavailable
        }
        let generation = self.generation
        defer { if generation == self.generation { delivering.remove(opID) } }

        let attempt = record.attempt
        if record.state == .queued {
            record.state = .sentNoAck
            try save(record)
        }
        let envelope = WCEnvelope(message: .write(attempt), sentAt: now())
        let reply: Data
        do {
            reply = try await channel.sendMessage(EnvelopeCodec.encode(envelope))
        } catch {
            guard generation == self.generation else { return }
            throw error
        }
        guard generation == self.generation else { return }
        guard case let .ack(ack) = try EnvelopeCodec.decode(reply).message,
              ack.persisted, ack.opID == opID, ack.attempt == attempt.number else {
            throw WatchOutboxError.invalidAck
        }
        if var current = records[opID], current.attempt == attempt, current.state == .sentNoAck {
            current.state = .handedToPhone
            try save(current)
        }
    }

    @discardableResult
    public func retry(_ opID: UUID) throws -> WriteAttempt {
        guard var record = records[opID] else { throw WatchOutboxError.unknownOperation }
        guard record.canRetry, isWithinRetention(record) else { throw WatchOutboxError.retryUnavailable }
        record.attempt = WriteAttempt(opID: opID, number: record.attempt.number + 1, payload: record.attempt.payload)
        record.state = .queued
        try save(record)
        return record.attempt
    }

    public func apply(_ result: OperationResult) throws {
        try merge([result])
    }

    public func apply(snapshot: InboxSnapshot) throws {
        try merge(snapshot.recentOps)
    }

    private func merge(_ results: [OperationResult]) throws {
        var next = records
        for result in results {
            guard var record = next[result.opID], (1...record.attempt.number).contains(result.attempt) else { continue }
            let index = record.results.firstIndex { $0.key == result.key }
            if let index {
                guard result.advances(record.results[index]) else { continue }
                record.results[index] = result
            } else {
                record.results.append(result)
            }
            if result.attempt == record.attempt.number {
                record.state = WatchRecord.State(result.result)
            }
            next[result.opID] = record
        }
        if next != records {
            try store.save(Array(next.values))
            records = next
        }
    }

    private func isWithinRetention(_ record: WatchRecord) -> Bool {
        record.createdAt > now() - PhoneRelay.retentionMilliseconds
    }

    private func save(_ record: WatchRecord) throws {
        var next = records
        next[record.attempt.opID] = record
        try store.save(Array(next.values))
        records = next
    }
}
