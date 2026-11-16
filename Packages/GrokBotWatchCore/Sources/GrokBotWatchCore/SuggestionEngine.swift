import Foundation

public protocol SuggestionModel: Sendable {
    func suggest(for text: String) async throws -> [String]
}

public struct SuggestionEngine: Sendable {
    private let model: (any SuggestionModel)?

    public init(model: (any SuggestionModel)? = nil) {
        self.model = model
    }

    public func suggestions(for text: String, widget: Widget? = nil) async -> [String] {
        if let widget {
            return Self.validCandidates(widget.options.map(\.label))
        }
        if let model, let generated = try? await model.suggest(for: text) {
            let valid = Self.validCandidates(generated)
            if valid.count >= 2 { return valid }
        }
        return Self.rules(for: text)
    }

    static func validCandidates(_ candidates: [String]) -> [String] {
        let links = #"(?i)(?:[a-z][a-z0-9+.-]*://|www\.|\[[^\]]+\]\(|\b[\w-]+\.(?:com|net|org|io|ai|dev)\b)"#
        let secrets = #"(?i)(?:(?:s[k]|xai)[-][\w-]+|gh[pours]_[\w-]+|github[_]pat[_][\w-]+|\bbearer\s+\S+|\bprivate\s+key\b|\b(?:api[_ -]?key|password|refresh[_ -]?token)\s*[:=])"#
        var seen: Set<String> = []
        var replies: [String] = []
        for candidate in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...40).contains(text.count),
                  !text.contains(where: \.isNewline),
                  text.range(of: links, options: .regularExpression) == nil,
                  text.range(of: secrets, options: .regularExpression) == nil,
                  seen.insert(text.lowercased()).inserted else { continue }
            replies.append(text)
            if replies.count == 4 { break }
        }
        return replies
    }

    private static func rules(for text: String) -> [String] {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chinese = question.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        if question.contains("还是") || question.contains(" or ") {
            return chinese ? ["选第一项", "选第二项", "请解释选项"] : ["The first option", "The second option", "Please explain the options"]
        }
        let firstWord = question.split(whereSeparator: \.isWhitespace).first
        let yesNo = Set(["am", "are", "can", "could", "did", "do", "does", "has", "have", "is", "may", "should", "will", "would"])
        if question.hasSuffix("吗？") || question.hasSuffix("吗?") || firstWord.map({ yesNo.contains(String($0)) }) == true {
            return chinese ? ["是", "否", "稍后再说"] : ["Yes", "No", "Later"]
        }
        return chinese ? ["请继续", "请展开说明", "稍后回复"] : ["Please continue", "Please explain", "I'll reply later"]
    }
}
