import Foundation

public enum ReplySource: String, Codable, Sendable {
    case suggestion
    case card
    case dictation
}

public enum WritePayload: Codable, Equatable, Sendable {
    case message(botID: String, text: String, source: ReplySource)
    case widget(botID: String, entryID: String, reply: WidgetReply)
    case approval(botID: String, approvalID: String, decision: ApprovalDecision)
    case form(botID: String, formID: String, reply: FormReply)

    public var botID: String {
        switch self {
        case let .message(botID, _, _), let .widget(botID, _, _),
             let .approval(botID, _, _), let .form(botID, _, _):
            return botID
        }
    }

    var entryID: String? {
        switch self {
        case .message: return nil
        case let .widget(_, id, _), let .approval(_, id, _), let .form(_, id, _): return id
        }
    }

    var isValid: Bool {
        guard !botID.isEmpty else { return false }
        switch self {
        case let .message(_, text, _): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .widget(_, id, .answer(values)): return !id.isEmpty && !values.isEmpty
        case let .widget(_, id, .dismiss), let .approval(_, id, _), let .form(_, id, _): return !id.isEmpty
        }
    }
}

public struct WriteAttempt: Codable, Equatable, Sendable {
    public static let limit = 3
    public let opID: UUID
    public let number: Int
    public let payload: WritePayload

    public init(opID: UUID, number: Int, payload: WritePayload) {
        self.opID = opID
        self.number = number
        self.payload = payload
    }

    public var nonce: String? {
        guard case .message = payload else { return nil }
        return opID.uuidString.lowercased()
    }

    var key: AttemptKey { AttemptKey(opID: opID, attempt: number) }
}

struct AttemptKey: Hashable, Sendable {
    let opID: UUID
    let attempt: Int
}

public enum DeliveryStatus: String, Codable, Sendable {
    case accepted
    case rejected
    case notDelivered
    case unknown

    var isTerminal: Bool { self != .unknown }
}

public enum ResultReason: String, Codable, Sendable {
    case attempt
    case storage
    case expired
    case alreadyHandled
    case protocolFailure
    case invalidOperation
    case inProgress
}

public struct OperationResult: Codable, Equatable, Sendable {
    public let opID: UUID
    public let attempt: Int
    public let writesDone: Int
    public let result: DeliveryStatus
    public let reason: ResultReason?
    public let finishedAt: Int64

    public init(opID: UUID, attempt: Int, writesDone: Int, result: DeliveryStatus, reason: ResultReason? = nil, finishedAt: Int64) {
        self.opID = opID
        self.attempt = attempt
        self.writesDone = writesDone
        self.result = result
        self.reason = reason
        self.finishedAt = finishedAt
    }

    enum CodingKeys: String, CodingKey {
        case opID = "opId"
        case attempt, writesDone, result, reason, finishedAt
    }

    var key: AttemptKey { AttemptKey(opID: opID, attempt: attempt) }

    func advances(_ previous: OperationResult?) -> Bool {
        guard let previous else { return true }
        return !previous.result.isTerminal && result.isTerminal
    }
}

public struct OperationAck: Codable, Equatable, Sendable {
    public let opID: UUID
    public let attempt: Int
    public let persisted: Bool

    public init(opID: UUID, attempt: Int, persisted: Bool = true) {
        self.opID = opID
        self.attempt = attempt
        self.persisted = persisted
    }

    enum CodingKeys: String, CodingKey {
        case opID = "opId"
        case attempt, persisted
    }
}

func currentMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
}
