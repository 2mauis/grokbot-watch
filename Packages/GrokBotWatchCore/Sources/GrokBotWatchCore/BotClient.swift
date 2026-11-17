import Foundation

public enum BotHarness: String, Codable, Sendable {
    case gateway
    case server
}

public struct Bot: Codable, Equatable, Sendable {
    public let id: String
    public let harness: BotHarness
    public let isPrimary: Bool

    public init(id: String, harness: BotHarness, isPrimary: Bool) {
        self.id = id
        self.harness = harness
        self.isPrimary = isPrimary
    }
}

public enum EntryResolution: Codable, Equatable, Sendable {
    case pending
    case widgetAnswered([String])
    case widgetDismissed
    case approvalResolved(ApprovalDecision)
    case formSubmitted([String: FormValue]?)
    case formDismissed
    case expired
}

public struct RemoteEntry: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case bot
    }

    public let id: String
    public let role: Role
    public let text: String?
    public let nonce: String?
    public let resolution: EntryResolution?

    public init(id: String, role: Role, text: String? = nil, nonce: String? = nil, resolution: EntryResolution? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.nonce = nonce
        self.resolution = resolution
    }
}

public enum BotOperation: Equatable, Sendable {
    case list, transcript, getSendStatus
    case send, respondToWidget, dismissWidget, resolveApproval, submitForm, dismissForm

    public var isWrite: Bool {
        switch self {
        case .list, .transcript, .getSendStatus: return false
        default: return true
        }
    }
}

public enum BotRoute: Equatable, Sendable {
    case gateway(String)
    case server(String)
}

public struct BotRequest: Equatable, Sendable {
    public let operation: BotOperation
    public let route: BotRoute
    public let botID: String?
    public let nonce: String?
    public let payload: WritePayload?
    public let timeout: Duration
    public let responseLimit = 1_048_576
    public let followsRedirects = false

    fileprivate init(
        operation: BotOperation, route: BotRoute, botID: String? = nil, nonce: String? = nil,
        payload: WritePayload? = nil, timeout: Duration = .seconds(30)
    ) {
        self.operation = operation
        self.route = route
        self.botID = botID
        self.nonce = nonce
        self.payload = payload
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public enum HTTPTransportFailure: Error, Sendable {
    case timeout
    case disconnected
    case status(Int)
    case invalidResponse
}

/// Adapters encode each whitelisted request for its route and normalize validated wire responses
/// into the core DTOs. Malformed wire data must throw invalidResponse. Enforce the request's
/// timeout and byte limit on the wire, refuse redirects, and perform exactly one exchange per call.
public protocol HTTPTransport: Sendable {
    func exchange(_ request: BotRequest) async throws -> HTTPResponse
}

public enum BotClientError: Error, Equatable {
    case degraded(BotOperation)
    case invalidOperation
}

public enum ProtocolGuard {
    static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse, for request: BotRequest) throws -> T {
        let code = response.statusCode
        guard response.body.count <= request.responseLimit else { throw BotClientError.degraded(request.operation) }
        guard (200..<300).contains(code) else {
            if (400..<500).contains(code), code != 408, code != 429 {
                throw BotClientError.degraded(request.operation)
            }
            if (300..<400).contains(code) { throw BotClientError.degraded(request.operation) }
            if code == 408 { throw HTTPTransportFailure.timeout }
            throw HTTPTransportFailure.status(code)
        }
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw BotClientError.degraded(request.operation)
        }
    }
}

public struct BotClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: some HTTPTransport) {
        self.transport = transport
    }

    public func listBots(harness: BotHarness = .gateway) async throws -> [Bot] {
        let request = BotRequest(operation: .list, route: route(harness, gateway: "list", server: "ListGrokBotAgents"))
        let bots = try await read([Bot].self, request)
        guard bots.allSatisfy({ !$0.id.isEmpty }), Set(bots.map(\.id)).count == bots.count else {
            throw BotClientError.degraded(.list)
        }
        return bots
    }

    public func transcript(for bot: Bot) async throws -> [RemoteEntry] {
        guard !bot.id.isEmpty else { throw BotClientError.invalidOperation }
        let request = BotRequest(
            operation: .transcript, route: route(bot.harness, gateway: "transcript", server: "ListGrokBotTranscriptEntries"),
            botID: bot.id
        )
        let entries = try await read([RemoteEntry].self, request)
        guard entries.allSatisfy({ !$0.id.isEmpty }) else { throw BotClientError.degraded(.transcript) }
        return entries
    }

    func sendStatus(for bot: Bot, nonce: String, timeout: Duration) async throws -> DeliveryStatus {
        guard bot.harness == .server, !bot.id.isEmpty else { throw BotClientError.invalidOperation }
        return try await exchange(
            DeliveryStatus.self,
            BotRequest(operation: .getSendStatus, route: .server("GetGrokBotSendStatus"), botID: bot.id, nonce: nonce, timeout: timeout)
        )
    }

    func write(_ attempt: WriteAttempt, for bot: Bot) async throws -> DeliveryStatus {
        guard attempt.payload.isValid, attempt.payload.botID == bot.id,
              (1...WriteAttempt.limit).contains(attempt.number) else { throw BotClientError.invalidOperation }
        let (operation, gateway, server): (BotOperation, String, String)
        switch attempt.payload {
        case .message:
            (operation, gateway, server) = (.send, "send", "SendGrokBotUserMessage")
        case .widget(_, _, .answer):
            (operation, gateway, server) = (.respondToWidget, "respondToWidget", "RespondGrokBotWidget")
        case .widget(_, _, .dismiss):
            (operation, gateway, server) = (.dismissWidget, "dismissWidget", "DismissGrokBotWidget")
        case .approval:
            (operation, gateway, server) = (.resolveApproval, "resolveAutoReviewApproval", "ResolveGrokBotAutoReviewApproval")
        case .form(_, _, .submit):
            (operation, gateway, server) = (.submitForm, "submitUserForm", "SubmitGrokBotUserForm")
        case .form(_, _, .dismiss):
            (operation, gateway, server) = (.dismissForm, "dismissUserForm", "DismissGrokBotUserForm")
        }
        let request = BotRequest(
            operation: operation, route: route(bot.harness, gateway: gateway, server: server),
            botID: bot.id, nonce: attempt.nonce, payload: attempt.payload
        )
        return try await exchange(DeliveryStatus.self, request)
    }

    private func route(_ harness: BotHarness, gateway: String, server: String) -> BotRoute {
        switch harness {
        case .gateway: return .gateway(gateway)
        case .server: return .server(server)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, _ request: BotRequest) async throws -> T {
        do {
            return try await exchange(type, request)
        } catch HTTPTransportFailure.timeout {
            return try await exchange(type, request)
        }
    }

    private func exchange<T: Decodable>(_ type: T.Type, _ request: BotRequest) async throws -> T {
        try Task.checkCancellation()
        do {
            let response = try await transport.exchange(request)
            return try ProtocolGuard.decode(type, from: response, for: request)
        } catch HTTPTransportFailure.invalidResponse {
            throw BotClientError.degraded(request.operation)
        }
    }
}
