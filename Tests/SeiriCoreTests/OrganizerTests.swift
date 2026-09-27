import Foundation
@testable import SeiriCore

struct OrganizerTests {
    func fixture() throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let root = base.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }
    func put(_ value: String, _ url: URL) throws { try Data(value.utf8).write(to: url) }
    func plan(_ root: URL, names: [String]) throws -> Plan {
        Plan(version: 1, root: root.path, mode: .downloads, createdAt: Date(), moves: try names.map {
            Move(name: $0, category: .documents, sha256: try FileSafety.digest(root.appendingPathComponent($0)), reason: "test", extraction: "test")
        })
    }
    func roundTripAndRepeatedUndo() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try put("領収書の内容", root.appendingPathComponent("資料 1.txt"))
        let plan = try plan(root, names: ["資料 1.txt"])
        let journal = base.appendingPathComponent("journal.json")
        try FileOperations().apply(plan, journalURL: journal)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("資料 1.txt").path))
        try expect(try String(contentsOf: root.appendingPathComponent("documents/資料 1.txt"), encoding: .utf8) == "領収書の内容")
        try FileOperations().undo(journalURL: journal)
        try FileOperations().undo(journalURL: journal)
        try expect(try FileSafety.digest(root.appendingPathComponent("資料 1.txt")) == plan.moves[0].sha256)
    }
    func collisionPreflightsWholeBatch() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        for name in ["a.txt", "b.txt"] { try put(name, root.appendingPathComponent(name)) }
        let plan = try plan(root, names: ["a.txt", "b.txt"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("documents"), withIntermediateDirectories: false)
        try put("existing", root.appendingPathComponent("documents/b.txt"))
        try expectThrows { try FileOperations().apply(plan, journalURL: base.appendingPathComponent("journal.json")) }
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        try expect(try String(contentsOf: root.appendingPathComponent("documents/b.txt"), encoding: .utf8) == "existing")
    }
    func changedSourceAndChangedDestinationAreRejected() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let source = root.appendingPathComponent("a.txt")
        try put("before", source)
        let plan = try plan(root, names: ["a.txt"])
        try put("after", source)
        let journal = base.appendingPathComponent("journal.json")
        try expectThrows { try FileOperations().apply(plan, journalURL: journal) }
        try put("before", source)
        try FileOperations().apply(plan, journalURL: journal)
        try put("edited", root.appendingPathComponent("documents/a.txt"))
        try expectThrows { try FileOperations().undo(journalURL: journal) }
    }
    func symlinkDestinationIsRejected() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try put("test", root.appendingPathComponent("a.txt"))
        let plan = try plan(root, names: ["a.txt"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("documents"), withDestinationURL: base)
        try expectThrows { try FileOperations().apply(plan, journalURL: base.appendingPathComponent("journal.json")) }
        try expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("a.txt").path))
    }
    func pathTraversalAndDuplicateEntriesAreRejected() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let bad = Move(name: "../outside", category: .documents, sha256: String(repeating: "a", count: 64), reason: "", extraction: "")
        let invalid = Plan(version: 1, root: root.path, mode: .downloads, createdAt: Date(), moves: [bad])
        try expectThrows { _ = try FileSafety.validate(invalid) }
        try put("a", root.appendingPathComponent("a.txt"))
        let duplicates = try plan(root, names: ["a.txt", "a.txt"])
        try expectThrows { _ = try FileSafety.validate(duplicates) }
    }
    func interruptedApplyCanBeUndone() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        for name in ["a.txt", "b.txt", "c.txt"] { try put(name, root.appendingPathComponent(name)) }
        let plan = try plan(root, names: ["a.txt", "b.txt", "c.txt"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("documents"), withIntermediateDirectories: false)
        // a moved before interruption; b marked moving but not yet moved; c untouched.
        try FileSafety.move(root.appendingPathComponent("a.txt"), root.appendingPathComponent("documents/a.txt"))
        let journal = base.appendingPathComponent("journal.json")
        try JSONFile.write(Journal(version: 1, plan: plan, states: [.moving, .moving, .pending]), to: journal)
        try FileOperations().undo(journalURL: journal)
        for move in plan.moves { try expect(try FileSafety.digest(root.appendingPathComponent(move.name)) == move.sha256) }
    }
    func interruptedUndoAndOriginalCollision() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let source = root.appendingPathComponent("a.txt")
        try put("original", source)
        let plan = try plan(root, names: ["a.txt"])
        let journal = base.appendingPathComponent("journal.json")
        try FileOperations().apply(plan, journalURL: journal)
        try put("new file", source)
        try expectThrows { try FileOperations().undo(journalURL: journal) }
        try expect(try String(contentsOf: source, encoding: .utf8) == "new file")
        try FileManager.default.removeItem(at: source)
        try FileSafety.move(root.appendingPathComponent("documents/a.txt"), source)
        try JSONFile.write(Journal(version: 1, plan: plan, states: [.undoing]), to: journal)
        try FileOperations().undo(journalURL: journal)
    }
    @MainActor func scanSkipsHiddenSymlinksFoldersAndDownloads() async throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        for name in ["a.txt", ".hidden", "incomplete.crdownload"] { try put("content", root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("a.txt"))
        let plan = try await Planner().make(root: root, mode: .downloads, classifier: RulesClassifier())
        try expect(plan.moves.map(\.name) == ["a.txt"])
        try expect(plan.moves[0].category == .documents)
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }
    func modelOutputCannotSelectArbitraryPaths() throws {
        let good = try Decision.parse(#"{"category":"invoices","reason":"請求書"}"#, mode: .work)
        try expect(good.category == .invoices)
        for text in [#"{"category":"../../outside","reason":"x"}"#, #"{"category":"images","reason":"x"}"#, "not json"] {
            try expectThrows { _ = try Decision.parse(text, mode: .work) }
        }
    }
    func journalAndPlanMustBeOutsideInput() throws {
        let (base, root) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try expectThrows { try FileSafety.requireOutside(root.appendingPathComponent("plan.json"), root: root) }
    }
}


private func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else { throw SeiriError("Assertion failed: \(file):\(line)") }
}
private func expectThrows(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
    do { try body() } catch { return }
    throw SeiriError("Expected error: \(file):\(line)")
}
@main struct Checks {
    @MainActor static func main() async throws {
        let tests = OrganizerTests()
        try tests.roundTripAndRepeatedUndo()
        try tests.collisionPreflightsWholeBatch()
        try tests.changedSourceAndChangedDestinationAreRejected()
        try tests.symlinkDestinationIsRejected()
        try tests.pathTraversalAndDuplicateEntriesAreRejected()
        try tests.interruptedApplyCanBeUndone()
        try tests.interruptedUndoAndOriginalCollision()
        try await tests.scanSkipsHiddenSymlinksFoldersAndDownloads()
        try tests.modelOutputCannotSelectArbitraryPaths()
        try tests.journalAndPlanMustBeOutsideInput()
        print("10 checks passed")
    }
}
