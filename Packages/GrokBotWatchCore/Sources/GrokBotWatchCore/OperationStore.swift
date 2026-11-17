import Foundation

/// A store belongs to one outbox or relay writer. A throwing save must leave the previous
/// snapshot intact, and returning from save is the write-ahead boundary.
public protocol OperationStore<Record>: Sendable {
    associatedtype Record: Codable & Sendable

    func load() throws -> [Record]
    func save(_ records: [Record]) throws
}

public struct JSONOperationStore<Record: Codable & Sendable>: OperationStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [Record] {
        do {
            return try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    public func save(_ records: [Record]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }
}

public enum OperationStoreError: Error {
    case duplicateRecord
}
