import Foundation

public enum AnswerError: Error {
    case invalidSelection
    case unsupportedForm
    case invalidFields
}

public struct WidgetOption: Codable, Equatable, Sendable {
    public let label: String
    public let value: String?

    public init(label: String, value: String? = nil) {
        self.label = label
        self.value = value
    }

    public var answerValue: String { value ?? label }
}

public enum WidgetReply: Codable, Equatable, Sendable {
    case answer([String])
    case dismiss

    public var submittedValue: String? {
        guard case let .answer(values) = self else { return nil }
        return values.joined(separator: "\n")
    }
}

public struct Widget: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case single, multiple }

    public let mode: Mode
    public let options: [WidgetOption]

    public init(mode: Mode, options: [WidgetOption]) {
        self.mode = mode
        self.options = options
    }

    public func answer(indexes: Set<Int>) throws -> WidgetReply {
        guard !indexes.isEmpty,
              mode == .multiple || indexes.count == 1,
              indexes.allSatisfy(options.indices.contains) else { throw AnswerError.invalidSelection }
        return .answer(indexes.sorted().map { options[$0].answerValue })
    }
}

public enum ApprovalDecision: String, Codable, CaseIterable, Sendable {
    case allow
    case deny
}

public enum FormValue: Codable, Equatable, Sendable {
    case text(String)
    case boolean(Bool)

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) {
            self = .boolean(boolean)
        } else {
            self = .text(try value.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .text(text): try value.encode(text)
        case let .boolean(boolean): try value.encode(boolean)
        }
    }
}

public struct FormField: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case singleLine
        case singleChoice([String])
        case yesNo
        case unsupported

        fileprivate func allows(_ value: FormValue) -> Bool {
            switch (self, value) {
            case let (.singleLine, .text(text)):
                return !text.contains(where: \.isNewline)
            case let (.singleChoice(options), .text(text)):
                return options.contains(text)
            case (.yesNo, .boolean):
                return true
            default:
                return false
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let required: Bool

    public init(id: String, kind: Kind, required: Bool) {
        self.id = id
        self.kind = kind
        self.required = required
    }
}

public enum FormReply: Codable, Equatable, Sendable {
    case submit([String: FormValue])
    case dismiss
}

public struct UserForm: Codable, Equatable, Sendable {
    public let fields: [FormField]

    public init(fields: [FormField]) {
        self.fields = fields
    }

    public var isSupported: Bool {
        Set(fields.map(\.id)).count == fields.count && fields.allSatisfy { $0.kind != .unsupported }
    }

    public func submit(_ values: [String: FormValue]) throws -> FormReply {
        guard isSupported else { throw AnswerError.unsupportedForm }
        guard Set(values.keys).isSubset(of: Set(fields.map(\.id))) else { throw AnswerError.invalidFields }
        for field in fields {
            guard let value = values[field.id] else {
                if field.required { throw AnswerError.invalidFields }
                continue
            }
            guard field.kind.allows(value) else { throw AnswerError.invalidFields }
            if case let .text(text) = value, field.required, text.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AnswerError.invalidFields
            }
        }
        return .submit(values)
    }
}
