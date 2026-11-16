import Foundation
import GrokBotWatchCore
import Testing

@Suite struct EnvelopeCodecTests {
    @Test func roundTripsFlattenedWriteEnvelope() throws {
        let envelope = WCEnvelope(message: .write(messageAttempt(2)), sentAt: exampleTime)
        let encoded = try EnvelopeCodec.encode(envelope)
        #expect(try EnvelopeCodec.decode(encoded) == envelope)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["type"] as? String == "reply.send")
        let body = try #require(object["body"] as? [String: Any])
        #expect(body["attempt"] as? Int == 2)
        #expect(body["opId"] as? String == messageAttempt().nonce)
        #expect(body["botId"] as? String == exampleBot.id)
    }

    @Test func unsupportedVersionCanBeReportedBeforeDecodingItsBody() throws {
        let data = Data(#"{"v":2,"type":"future","body":null}"#.utf8)
        #expect(throws: EnvelopeCodecError.unsupportedVersion(2)) { try EnvelopeCodec.decode(data) }
        let error = WCEnvelope(message: .versionError(supportedVersion: 1), sentAt: exampleTime)
        #expect(try EnvelopeCodec.decode(EnvelopeCodec.encode(error)) == error)
    }

    @Test func writeRequiresAttemptAndKnownType() throws {
        let data = Data(#"{"v":1,"id":"c05944d2-25ba-45ff-8ba6-112233445566","type":"reply.send","sentAt":0,"body":{"opId":"c05944d2-25ba-45ff-8ba6-112233445566","botId":"bot-1","text":"Okay","source":"suggestion"}}"#.utf8)
        #expect(throws: EnvelopeCodecError.invalidEnvelope) { try EnvelopeCodec.decode(data) }
    }
}

@Suite struct WidgetAnswerTests {
    @Test func fallsBackToLabelAndJoinsMultipleValuesInOptionOrder() throws {
        let widget = Widget(mode: .multiple, options: [
            WidgetOption(label: "First", value: "choice-a"), WidgetOption(label: "Second"),
        ])
        #expect(try widget.answer(indexes: [1, 0]) == .answer(["choice-a", "Second"]))
        #expect(try widget.answer(indexes: [0, 1]).submittedValue == "choice-a\nSecond")
        #expect(WidgetReply.dismiss.submittedValue == nil)
    }

    @Test func singleChoiceRejectsInvalidOrMultipleIndexes() {
        let widget = Widget(mode: .single, options: [WidgetOption(label: "First"), WidgetOption(label: "Second")])
        #expect(throws: AnswerError.invalidSelection) { try widget.answer(indexes: [0, 1]) }
        #expect(throws: AnswerError.invalidSelection) { try widget.answer(indexes: [2]) }
    }
}

@Suite struct ApprovalTests {
    @Test func allowsOnlyOneTimeApprovalAndDenial() throws {
        #expect(ApprovalDecision.allCases == [.allow, .deny])
        #expect(try JSONDecoder().decode(ApprovalDecision.self, from: Data(#""allow""#.utf8)) == .allow)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ApprovalDecision.self, from: Data(#""always""#.utf8))
        }
    }
}

@Suite struct UserFormSupportTests {
    @Test func validatesFieldTypesChoicesAndRequiredValues() throws {
        let form = UserForm(fields: [
            FormField(id: "text", kind: .singleLine, required: true),
            FormField(id: "choice", kind: .singleChoice(["option-a", "option-b"]), required: true),
            FormField(id: "bool", kind: .yesNo, required: true),
        ])
        let values: [String: FormValue] = ["text": .text("Continue"), "choice": .text("option-b"), "bool": .boolean(false)]
        #expect(form.isSupported)
        #expect(try form.submit(values) == .submit(values))
        #expect(throws: AnswerError.invalidFields) { try form.submit(["text": .text("More\nthan one line")]) }
    }

    @Test func unknownFieldKeepsFormOnPhone() {
        let form = UserForm(fields: [FormField(id: "file", kind: .unsupported, required: true)])
        #expect(!form.isSupported)
        #expect(throws: AnswerError.unsupportedForm) { try form.submit([:]) }
    }
}

private struct FakeSuggestionModel: SuggestionModel {
    var output: [String]
    var unavailable = false

    func suggest(for text: String) throws -> [String] {
        if unavailable { throw TestFailure.disconnected }
        return output
    }
}

@Suite struct SuggestionEngineTests {
    @Test func filtersUnsafeDuplicateOrOverlongModelOutput() async {
        let engine = SuggestionEngine(model: FakeSuggestionModel(output: [
            "  Continue ", "continue", "Please explain", String(repeating: "x", count: 41),
            "https" + "://" + "example.invalid", "Here is a private " + "key",
        ]))
        #expect(await engine.suggestions(for: exampleText) == ["Continue", "Please explain"])
    }

    @Test func limitsCandidateCount() async {
        let engine = SuggestionEngine(model: FakeSuggestionModel(output: ["One", "Two", "Three", "Four", "Five"]))
        #expect(await engine.suggestions(for: exampleText) == ["One", "Two", "Three", "Four"])
    }
}

@Suite struct SuggestionFallbackTests {
    @Test func widgetOptionsTakePriorityOverModel() async {
        let engine = SuggestionEngine(model: FakeSuggestionModel(output: ["Model A", "Model B"]))
        #expect(await engine.suggestions(for: exampleText, widget: Widget(mode: .single, options: [WidgetOption(label: "First")])) == ["First"])
    }

    @Test func unavailableOrInsufficientModelFallsBackToRules() async {
        let unavailable = SuggestionEngine(model: FakeSuggestionModel(output: [], unavailable: true))
        let insufficient = SuggestionEngine(model: FakeSuggestionModel(output: ["One"]))
        for engine in [unavailable, insufficient] {
            let reply = await engine.suggestions(for: "Should I continue?")
            #expect(reply.starts(with: ["Yes", "No"]))
            #expect((2...4).contains(reply.count))
        }
    }
}

@Suite struct InboxSnapshotTests {
    @Test func includesMainBotsPendingItemsAndLatestMatchingSuggestions() {
        let transcript = [
            InboxEntry(botID: exampleBot.id, id: "closed", kind: .approval, text: "Handled", isPending: false, sentAt: 1),
            InboxEntry(botID: sandboxBot.id, id: "other", kind: .form, text: "Other Bot", isPending: true, sentAt: 4),
            InboxEntry(botID: exampleBot.id, id: "widget-1", kind: .widget, text: "Choose one", isPending: true, sentAt: 2),
            InboxEntry(botID: exampleBot.id, id: "reply-1", kind: .message, text: "Continue?", isPending: true, sentAt: 3),
        ]
        let snapshot = InboxBuilder.build(
            bots: [sandboxBot, exampleBot], entries: transcript,
            suggestions: SuggestionSet(botID: exampleBot.id, entryID: "reply-1", replies: ["Yes", "No"]), generatedAt: exampleTime
        )
        #expect(snapshot.inbox.map(\.id) == ["reply-1", "widget-1"])
        #expect(snapshot.latestMessage?.id == "reply-1")
        #expect(snapshot.suggestions == ["Yes", "No"])
        let stale = InboxBuilder.build(bots: [exampleBot], entries: transcript,
            suggestions: SuggestionSet(botID: exampleBot.id, entryID: "widget-1", replies: ["First"]), generatedAt: exampleTime)
        #expect(stale.suggestions.isEmpty)
    }
}
