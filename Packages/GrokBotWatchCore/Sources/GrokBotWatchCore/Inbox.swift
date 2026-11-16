import Foundation

public struct InboxEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case message, widget, approval, form }

    public let botID: String
    public let id: String
    public let kind: Kind
    public let text: String
    public let isPending: Bool
    public let sentAt: Int64

    public init(botID: String, id: String, kind: Kind, text: String, isPending: Bool, sentAt: Int64) {
        self.botID = botID
        self.id = id
        self.kind = kind
        self.text = text
        self.isPending = isPending
        self.sentAt = sentAt
    }

    enum CodingKeys: String, CodingKey {
        case botID = "botId"
        case id, kind, text, isPending, sentAt
    }
}

public struct SuggestionSet: Sendable {
    public let botID: String
    public let entryID: String
    public let replies: [String]

    public init(botID: String, entryID: String, replies: [String]) {
        self.botID = botID
        self.entryID = entryID
        self.replies = replies
    }
}

public enum ProtocolState: String, Codable, Sendable {
    case available
    case degraded
}

public struct InboxSnapshot: Codable, Equatable, Sendable {
    public let inbox: [InboxEntry]
    public let latestMessage: InboxEntry?
    public let suggestions: [String]
    public let cards: [String]
    public let suggestionsTruncated: Bool
    public let cardsTruncated: Bool
    public internal(set) var recentOps: [OperationResult]
    public let authState: AuthState
    public let protocolState: ProtocolState
    public let generatedAt: Int64

    public init(
        inbox: [InboxEntry] = [], latestMessage: InboxEntry? = nil, suggestions: [String] = [], cards: [String] = [],
        suggestionsTruncated: Bool = false, cardsTruncated: Bool = false, recentOps: [OperationResult] = [],
        authState: AuthState = .signedOut, protocolState: ProtocolState = .available, generatedAt: Int64
    ) {
        self.inbox = inbox
        self.latestMessage = latestMessage
        self.suggestions = suggestions
        self.cards = cards
        self.suggestionsTruncated = suggestionsTruncated
        self.cardsTruncated = cardsTruncated
        self.recentOps = recentOps
        self.authState = authState
        self.protocolState = protocolState
        self.generatedAt = generatedAt
    }
}

public enum InboxBuilder {
    public static func build(
        bots: [Bot], entries: [InboxEntry], suggestions: SuggestionSet? = nil,
        authState: AuthState = .signedOut, protocolState: ProtocolState = .available, generatedAt: Int64
    ) -> InboxSnapshot {
        let primary = bots.filter(\.isPrimary)
        guard primary.count == 1, let bot = primary.first else {
            return InboxSnapshot(authState: authState, protocolState: protocolState, generatedAt: generatedAt)
        }
        let sorted = entries.filter { $0.botID == bot.id }.sorted {
            $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt > $1.sentAt
        }
        let latest = sorted.first { $0.kind == .message }
        let matching = suggestions.flatMap { candidate -> [String]? in
            guard let latest, latest.isPending, latest.botID == candidate.botID, latest.id == candidate.entryID else { return nil }
            return candidate.replies
        } ?? []
        let filtered = SuggestionEngine.validCandidates(matching)
        return InboxSnapshot(
            inbox: sorted.filter(\.isPending), latestMessage: latest, suggestions: filtered,
            suggestionsTruncated: filtered.count < matching.count,
            authState: authState, protocolState: protocolState, generatedAt: generatedAt
        )
    }
}
