import Foundation

public protocol WCChannel: Sendable {
    func sendMessage(_ data: Data) async throws -> Data
    func transferUserInfo(_ data: Data) async throws
    func updateApplicationContext(_ data: Data) async throws
}

public enum WCMessage: Equatable, Sendable {
    case refreshInbox(botID: String?)
    case write(WriteAttempt)
    case ack(OperationAck)
    case result(OperationResult)
    case snapshot(InboxSnapshot)
    case versionError(supportedVersion: Int)
}

public struct WCEnvelope: Equatable, Sendable {
    public let id: UUID
    public let message: WCMessage
    public let sentAt: Int64

    public init(id: UUID = UUID(), message: WCMessage, sentAt: Int64? = nil) {
        self.id = id
        self.message = message
        self.sentAt = sentAt ?? currentMilliseconds()
    }
}

public enum EnvelopeCodecError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidEnvelope
    case snapshotTooLarge
}

public enum EnvelopeCodec {
    public static let version = 1
    public static let snapshotLimit = 64 * 1_024

    public static func encode(_ envelope: WCEnvelope) throws -> Data {
        let data = try JSONEncoder().encode(WireEnvelope(envelope))
        try checkSnapshotSize(envelope, size: data.count)
        return data
    }

    public static func decode(_ data: Data) throws -> WCEnvelope {
        let decoder = JSONDecoder()
        let envelope: WCEnvelope
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.v == version else { throw EnvelopeCodecError.unsupportedVersion(header.v) }
            if header.type == MessageType.snapshot.rawValue, data.count > snapshotLimit {
                throw EnvelopeCodecError.snapshotTooLarge
            }
            envelope = try decoder.decode(WireEnvelope.self, from: data).envelope
        } catch let error as EnvelopeCodecError {
            throw error
        } catch {
            throw EnvelopeCodecError.invalidEnvelope
        }
        return envelope
    }

    private static func checkSnapshotSize(_ envelope: WCEnvelope, size: Int) throws {
        if case .snapshot = envelope.message, size > snapshotLimit {
            throw EnvelopeCodecError.snapshotTooLarge
        }
    }

    private struct Header: Decodable {
        let v: Int
        let type: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: WireEnvelope.CodingKeys.self)
            v = try container.decode(Int.self, forKey: .v)
            type = try? container.decode(String.self, forKey: .type)
        }
    }
}

private enum MessageType: String, Codable {
    case refresh = "inbox.refresh"
    case send = "reply.send"
    case widgetResponse = "widget.respond"
    case widgetDismissal = "widget.dismiss"
    case approval = "approval.resolve"
    case formSubmission = "form.submit"
    case formDismissal = "form.dismiss"
    case ack = "op.ack"
    case result = "op.result"
    case snapshot = "inbox.snapshot"
    case versionError = "error.version"
}

private struct WireEnvelope: Codable {
    enum CodingKeys: String, CodingKey { case v, id, type, sentAt, body }
    private enum BodyKey: String, CodingKey {
        case opId, attempt, botId, text, source, entryId, values, approvalId, decision, formId, fields, supportedVersion
    }

    let envelope: WCEnvelope

    init(_ envelope: WCEnvelope) {
        self.envelope = envelope
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let type = try fields.decode(MessageType.self, forKey: .type)
        let id = try fields.decode(UUID.self, forKey: .id)
        let sentAt = try fields.decode(Int64.self, forKey: .sentAt)
        let message: WCMessage
        switch type {
        case .ack:
            let ack = try fields.decode(OperationAck.self, forKey: .body)
            guard ack.persisted, (1...WriteAttempt.limit).contains(ack.attempt) else { throw EnvelopeCodecError.invalidEnvelope }
            message = .ack(ack)
        case .result:
            let result = try fields.decode(OperationResult.self, forKey: .body)
            guard result.attempt >= 1, (0...WriteAttempt.limit).contains(result.writesDone) else { throw EnvelopeCodecError.invalidEnvelope }
            message = .result(result)
        case .snapshot:
            message = .snapshot(try fields.decode(InboxSnapshot.self, forKey: .body))
        case .refresh, .versionError:
            let body = try fields.nestedContainer(keyedBy: BodyKey.self, forKey: .body)
            if type == .refresh {
                message = .refreshInbox(botID: try body.decodeIfPresent(String.self, forKey: .botId))
            } else {
                message = .versionError(supportedVersion: try body.decode(Int.self, forKey: .supportedVersion))
            }
        case .send, .widgetResponse, .widgetDismissal, .approval, .formSubmission, .formDismissal:
            let body = try fields.nestedContainer(keyedBy: BodyKey.self, forKey: .body)
            message = .write(try Self.decodeWrite(type, from: body))
        }
        envelope = WCEnvelope(id: id, message: message, sentAt: sentAt)
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(EnvelopeCodec.version, forKey: .v)
        try fields.encode(envelope.id.uuidString.lowercased(), forKey: .id)
        try fields.encode(envelope.sentAt, forKey: .sentAt)
        switch envelope.message {
        case let .ack(ack):
            try fields.encode(MessageType.ack, forKey: .type)
            try fields.encode(ack, forKey: .body)
        case let .result(result):
            try fields.encode(MessageType.result, forKey: .type)
            try fields.encode(result, forKey: .body)
        case let .snapshot(snapshot):
            try fields.encode(MessageType.snapshot, forKey: .type)
            try fields.encode(snapshot, forKey: .body)
        case let .refreshInbox(botID):
            try fields.encode(MessageType.refresh, forKey: .type)
            var body = fields.nestedContainer(keyedBy: BodyKey.self, forKey: .body)
            try body.encodeIfPresent(botID, forKey: .botId)
        case let .versionError(version):
            try fields.encode(MessageType.versionError, forKey: .type)
            var body = fields.nestedContainer(keyedBy: BodyKey.self, forKey: .body)
            try body.encode(version, forKey: .supportedVersion)
        case let .write(attempt):
            try Self.encode(attempt, into: &fields)
        }
    }

    private static func decodeWrite(_ type: MessageType, from body: KeyedDecodingContainer<BodyKey>) throws -> WriteAttempt {
        let botID = try body.decode(String.self, forKey: .botId)
        let opID = try body.decode(UUID.self, forKey: .opId)
        let number = try body.decode(Int.self, forKey: .attempt)
        let payload: WritePayload
        switch type {
        case .send:
            let text = try body.decode(String.self, forKey: .text)
            let source = try body.decode(ReplySource.self, forKey: .source)
            payload = .message(botID: botID, text: text, source: source)
        case .widgetResponse, .widgetDismissal:
            let id = try body.decode(String.self, forKey: .entryId)
            let values = try body.decode([String].self, forKey: .values)
            if type == .widgetDismissal, !values.isEmpty { throw EnvelopeCodecError.invalidEnvelope }
            payload = .widget(botID: botID, entryID: id, reply: type == .widgetResponse ? .answer(values) : .dismiss)
        case .approval:
            let id = try body.decode(String.self, forKey: .approvalId)
            let decision = try body.decode(ApprovalDecision.self, forKey: .decision)
            payload = .approval(botID: botID, approvalID: id, decision: decision)
        case .formSubmission, .formDismissal:
            let id = try body.decode(String.self, forKey: .formId)
            let fields = try body.decode([String: FormValue].self, forKey: .fields)
            if type == .formDismissal, !fields.isEmpty { throw EnvelopeCodecError.invalidEnvelope }
            payload = .form(botID: botID, formID: id, reply: type == .formSubmission ? .submit(fields) : .dismiss)
        default:
            throw EnvelopeCodecError.invalidEnvelope
        }
        guard number >= 1, payload.isValid else { throw EnvelopeCodecError.invalidEnvelope }
        return WriteAttempt(opID: opID, number: number, payload: payload)
    }

    private static func encode(_ attempt: WriteAttempt, into fields: inout KeyedEncodingContainer<CodingKeys>) throws {
        guard attempt.number >= 1, attempt.payload.isValid else { throw EnvelopeCodecError.invalidEnvelope }
        var body = fields.nestedContainer(keyedBy: BodyKey.self, forKey: .body)
        try body.encode(attempt.opID.uuidString.lowercased(), forKey: .opId)
        try body.encode(attempt.number, forKey: .attempt)
        try body.encode(attempt.payload.botID, forKey: .botId)
        let type: MessageType
        switch attempt.payload {
        case let .message(_, text, source):
            type = .send
            try body.encode(text, forKey: .text)
            try body.encode(source, forKey: .source)
        case let .widget(_, id, reply):
            try body.encode(id, forKey: .entryId)
            switch reply {
            case let .answer(values):
                type = .widgetResponse
                try body.encode(values, forKey: .values)
            case .dismiss:
                type = .widgetDismissal
                try body.encode([String](), forKey: .values)
            }
        case let .approval(_, id, decision):
            type = .approval
            try body.encode(id, forKey: .approvalId)
            try body.encode(decision, forKey: .decision)
        case let .form(_, id, reply):
            try body.encode(id, forKey: .formId)
            switch reply {
            case let .submit(values):
                type = .formSubmission
                try body.encode(values, forKey: .fields)
            case .dismiss:
                type = .formDismissal
                try body.encode([String: FormValue](), forKey: .fields)
            }
        }
        try fields.encode(type, forKey: .type)
    }
}
