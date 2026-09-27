import Foundation
import CryptoKit
import Darwin

public enum FileSafety {
    static var fm: FileManager { FileManager.default }
    static func kind(_ url: URL) throws -> FileAttributeType? {
        do { return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    static func directory(_ url: URL) throws {
        guard try kind(url) == .typeDirectory else { throw SeiriError("実フォルダが必要です: \(url.path)") }
    }
    public static func digest(_ url: URL) throws -> String {
        guard try kind(url) == .typeRegular else { throw SeiriError("通常ファイルが必要です: \(url.path)") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verify(_ url: URL, hash: String) throws {
        guard try digest(url) == hash else { throw SeiriError("内容が変更されています: \(url.path)") }
    }
    static func absent(_ url: URL) throws {
        guard try kind(url) == nil else { throw SeiriError("既存のファイルやフォルダに上書きできません: \(url.path)") }
    }
    static func move(_ from: URL, _ to: URL) throws {
        // Atomic, same-volume, no overwrite even if a destination appears after validation.
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            throw SeiriError("移動できません: \(from.path) → \(to.path): \(String(cString: strerror(errno)))")
        }
    }
    public static func validate(_ plan: Plan) throws -> URL {
        let root = URL(fileURLWithPath: plan.root).standardizedFileURL
        guard plan.version == 1, plan.root.hasPrefix("/"), root.path == plan.root,
              root.resolvingSymlinksInPath().path == root.path else { throw SeiriError("不正な整理案のルートです") }
        try directory(root)
        var names = Set<String>()
        for move in plan.moves {
            guard !move.name.isEmpty, !move.name.hasPrefix("."),
                  !move.name.contains("/"), !move.name.contains("\0"),
                  names.insert(move.name).inserted,
                  Category.allowed(for: plan.mode).contains(move.category),
                  move.sha256.count == 64, move.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw SeiriError("不正または重複した移動項目です: \(move.name)")
            }
            let folder = root.appendingPathComponent(move.category.rawValue)
            if try kind(folder) != nil { try directory(folder) }
        }
        return root
    }
    public static func requireOutside(_ url: URL, root: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard path != rootPath, !path.hasPrefix(rootPath + "/") else {
            throw SeiriError("整理案・履歴は整理対象フォルダの外に保存してください")
        }
    }
}

private final class FolderLock {
    let fd: Int32
    init(_ root: URL) throws {
        let path = root.appendingPathComponent(".seiri.lock").path
        fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SeiriError("ロックを作成できません: \(path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw SeiriError("このフォルダは別のseiriプロセスが操作中です")
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

public struct FileOperations {
    public init() {}
    public func apply(_ plan: Plan, journalURL: URL) throws {
        let root = try FileSafety.validate(plan)
        let lock = try FolderLock(root)
        defer { withExtendedLifetime(lock) {} }
        try FileSafety.requireOutside(journalURL, root: root)
        try FileSafety.absent(journalURL)
        // Validate every entry before the first mutation.
        for move in plan.moves {
            try FileSafety.verify(root.appendingPathComponent(move.name), hash: move.sha256)
            try FileSafety.absent(root.appendingPathComponent(move.destination))
        }
        var journal = Journal(version: 1, plan: plan, states: Array(repeating: .pending, count: plan.moves.count))
        try JSONFile.write(journal, to: journalURL, new: true)
        do {
            for (index, move) in plan.moves.enumerated() {
                let folder = root.appendingPathComponent(move.category.rawValue)
                if try FileSafety.kind(folder) == nil {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                }
                try FileSafety.directory(folder)
                let source = root.appendingPathComponent(move.name)
                try FileSafety.verify(source, hash: move.sha256)
                journal.states[index] = .moving
                try JSONFile.write(journal, to: journalURL)
                try FileSafety.move(source, root.appendingPathComponent(move.destination))
                journal.states[index] = .moved
                try JSONFile.write(journal, to: journalURL)
            }
        } catch {
            throw SeiriError("整理が途中で停止しました: \(error.localizedDescription)\n復旧: seiri undo \(journalURL.path)")
        }
    }

    public func undo(journalURL: URL) throws {
        let initial = try JSONFile.read(Journal.self, from: journalURL)
        let root = try FileSafety.validate(initial.plan)
        let lock = try FolderLock(root)
        defer { withExtendedLifetime(lock) {} }
        // Re-read after acquiring the lock in case apply just finished.
        var journal = try JSONFile.read(Journal.self, from: journalURL)
        guard journal.version == 1, journal.plan.root == initial.plan.root,
              journal.states.count == journal.plan.moves.count else { throw SeiriError("不正な実行履歴です") }
        _ = try FileSafety.validate(journal.plan)
        try FileSafety.requireOutside(journalURL, root: root)
        var restore: [Int] = []
        for (index, move) in journal.plan.moves.enumerated() {
            let state = journal.states[index]
            if state == .pending || state == .undone { continue }
            let original = root.appendingPathComponent(move.name)
            let destination = root.appendingPathComponent(move.destination)
            if (state == .moving || state == .undoing),
               try FileSafety.kind(destination) == nil {
                try FileSafety.verify(original, hash: move.sha256)
                journal.states[index] = .undone
            } else {
                try FileSafety.verify(destination, hash: move.sha256)
                try FileSafety.absent(original)
                restore.append(index)
            }
        }
        try JSONFile.write(journal, to: journalURL)
        for index in restore.reversed() {
            let move = journal.plan.moves[index]
            let destination = root.appendingPathComponent(move.destination)
            try FileSafety.directory(destination.deletingLastPathComponent())
            try FileSafety.verify(destination, hash: move.sha256)
            journal.states[index] = .undoing
            try JSONFile.write(journal, to: journalURL)
            try FileSafety.move(destination, root.appendingPathComponent(move.name))
            journal.states[index] = .undone
            try JSONFile.write(journal, to: journalURL)
        }
    }
}
