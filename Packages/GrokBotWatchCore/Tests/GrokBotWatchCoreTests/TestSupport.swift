import Foundation
import GrokBotWatchCore

let exampleBot = Bot(id: "bot-1", harness: .server, isPrimary: true)
let sandboxBot = Bot(id: "bot-2", harness: .gateway, isPrimary: false)
let exampleID = UUID(uuidString: "C05944D2-25BA-45FF-8BA6-112233445566")!
let exampleText = "Please continue"
let exampleTime: Int64 = 20_000

func messageAttempt(_ number: Int = 1, bot: Bot = exampleBot) -> WriteAttempt {
    WriteAttempt(opID: exampleID, number: number, payload: .message(botID: bot.id, text: exampleText, source: .suggestion))
}

func result(_ status: DeliveryStatus, _ attempt: Int = 1, writesDone: Int? = nil) -> OperationResult {
    OperationResult(opID: exampleID, attempt: attempt, writesDone: writesDone ?? attempt, result: status, finishedAt: exampleTime)
}

enum TestFailure: Error {
    case disconnected
    case missingResponse
    case storage
}

actor TestHTTP: HTTPTransport {
    enum Step: Sendable {
        case response(HTTPResponse)
        case failure(HTTPTransportFailure)
    }

    private var steps: [Step]
    private(set) var requests: [BotRequest] = []
    private let onRequest: @Sendable (BotRequest) -> Void

    init(_ steps: [Step] = [], onRequest: @escaping @Sendable (BotRequest) -> Void = { _ in }) {
        self.steps = steps
        self.onRequest = onRequest
    }

    func exchange(_ request: BotRequest) throws -> HTTPResponse {
        requests.append(request)
        onRequest(request)
        guard !steps.isEmpty else { throw TestFailure.missingResponse }
        switch steps.removeFirst() {
        case let .response(response): return response
        case let .failure(error): throw error
        }
    }
}

func response<T: Encodable>(_ value: T, status: Int = 200) throws -> TestHTTP.Step {
    try .response(HTTPResponse(statusCode: status, body: JSONEncoder().encode(value)))
}

func rawResponse(_ string: String, status: Int = 200) -> TestHTTP.Step {
    .response(HTTPResponse(statusCode: status, body: Data(string.utf8)))
}

final class TestStore<Record: Codable & Sendable>: OperationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Record]
    private let rejectsSaves: Bool

    init(_ records: [Record] = [], rejectsSaves: Bool = false) {
        self.records = records
        self.rejectsSaves = rejectsSaves
    }

    func load() -> [Record] {
        lock.withLock { records }
    }

    func save(_ records: [Record]) throws {
        if rejectsSaves { throw TestFailure.storage }
        lock.withLock { self.records = records }
    }
}

actor TestWC: WCChannel {
    private(set) var messages: [Data] = []
    private(set) var results: [Data] = []
    private(set) var snapshot: Data?
    private let acknowledge: Bool
    private let beforeSend: @Sendable () -> Void

    init(acknowledge: Bool = true, beforeSend: @escaping @Sendable () -> Void = {}) {
        self.acknowledge = acknowledge
        self.beforeSend = beforeSend
    }

    func sendMessage(_ data: Data) throws -> Data {
        beforeSend()
        messages.append(data)
        guard acknowledge else { throw TestFailure.disconnected }
        let message = try EnvelopeCodec.decode(data).message
        guard case let .write(attempt) = message else { throw TestFailure.missingResponse }
        return try EnvelopeCodec.encode(WCEnvelope(message: .ack(OperationAck(opID: attempt.opID, attempt: attempt.number)), sentAt: exampleTime))
    }

    func transferUserInfo(_ data: Data) {
        results.append(data)
    }

    func updateApplicationContext(_ data: Data) {
        snapshot = data
    }
}

func relay(transport: some HTTPTransport, store: some OperationStore<RelayRecord>, wc: some WCChannel = TestWC()) throws -> PhoneRelay {
    try PhoneRelay(
        store: store,
        outbox: Outbox(client: BotClient(transport: transport), confirmationReadDelay: .zero, wait: { _ in }),
        channel: wc,
        now: { exampleTime }
    )
}
