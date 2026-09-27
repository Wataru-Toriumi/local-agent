import Foundation

public struct SeiriError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Mode: String, Codable, Sendable { case downloads, work }
public enum Category: String, Codable, CaseIterable, Sendable {
    case images, videos, audio, archives, installers, documents, code, other
    case invoices, contracts, meetings, reports, presentations, reference

    public static func allowed(for mode: Mode) -> [Category] {
        switch mode {
        case .downloads: return [.images, .videos, .audio, .archives, .installers, .documents, .code, .other]
        case .work: return [.invoices, .contracts, .meetings, .reports, .presentations, .reference, .other]
        }
    }
}
public struct Decision: Codable, Sendable {
    public let category: Category
    public let reason: String
    public init(category: Category, reason: String) {
        self.category = category; self.reason = reason
    }
    public static func parse(_ text: String, mode: Mode) throws -> Decision {
        let result = try JSONDecoder().decode(Decision.self, from: Data(text.utf8))
        guard Category.allowed(for: mode).contains(result.category),
              !result.reason.isEmpty, result.reason.count <= 500 else {
            throw SeiriError("モデルの分類結果が不正です。ファイルは移動していません。")
        }
        return result
    }
}
public struct FileContext: Sendable {
    public let name: String
    public let excerpt: String
    public let extraction: String
}
@MainActor public protocol Classifier {
    func classify(_ file: FileContext, mode: Mode) async throws -> Decision
}
public struct Move: Codable, Sendable {
    public let name: String
    public let category: Category
    public let sha256: String
    public let reason: String
    public let extraction: String
    public var destination: String { "\(category.rawValue)/\(name)" }
}
public struct Plan: Codable, Sendable {
    public let version: Int
    public let root: String
    public let mode: Mode
    public let createdAt: Date
    public let moves: [Move]
}
public enum MoveState: String, Codable, Sendable { case pending, moving, moved, undoing, undone }
public struct Journal: Codable, Sendable {
    public let version: Int
    public let plan: Plan
    public var states: [MoveState]
}
public enum JSONFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public static func write<T: Encodable>(_ value: T, to url: URL, new: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: new ? [.withoutOverwriting] : [.atomic])
    }
}
