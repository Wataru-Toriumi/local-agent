import Foundation
import PDFKit

@MainActor public struct Planner {
    public init() {}
    public func make(root: URL, mode: Mode, classifier: any Classifier) async throws -> Plan {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        try FileSafety.directory(root)
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var moves: [Move] = []
        for file in files {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  !["download", "crdownload", "part", "tmp"].contains(file.pathExtension.lowercased()) else { continue }
            let digest = try FileSafety.digest(file)
            let context = try Self.context(file)
            let decision = try await classifier.classify(context, mode: mode)
            guard Category.allowed(for: mode).contains(decision.category) else {
                throw SeiriError("許可されていない分類: \(decision.category.rawValue)")
            }
            guard try FileSafety.digest(file) == digest else {
                throw SeiriError("分類中に変更されました: \(file.lastPathComponent)")
            }
            moves.append(Move(name: file.lastPathComponent, category: decision.category,
                              sha256: digest, reason: decision.reason, extraction: context.extraction))
        }
        return Plan(version: 1, root: root.path, mode: mode, createdAt: Date(), moves: moves)
    }

    static func context(_ url: URL) throws -> FileContext {
        let ext = url.pathExtension.lowercased()
        var text = ""
        var extraction = "filename-only"
        if ["txt", "md", "csv", "tsv", "json", "yaml", "yml", "log", "html", "swift", "py", "js"].contains(ext) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            text = String(decoding: try handle.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
            extraction = "text-prefix"
        } else if ext == "pdf" {
            // Bound input size and extracted pages; scanned PDFs require OCR (not included).
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size <= 20_000_000, let document = PDFDocument(url: url), !document.isLocked {
                text = (0..<min(document.pageCount, 3)).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { extraction = "pdf-first-3-pages" }
            }
        }
        return FileContext(name: url.lastPathComponent, excerpt: String(text.prefix(4_000)), extraction: extraction)
    }
}

/// Explicit baseline for testing and deterministic extension-based organization.
@MainActor public struct RulesClassifier: Classifier {
    public init() {}
    public func classify(_ file: FileContext, mode: Mode) async throws -> Decision {
        guard mode == .downloads else {
            return Decision(category: .other, reason: "ルールモードでは資料の内容を判定しません")
        }
        return Decision(category: Self.category(for: file.name) ?? .other,
                        reason: "拡張子による分類（Qwen未使用）")
    }

    public static func category(for filename: String) -> Category? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let groups: [(Category, [String])] = [
            (.images, ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"]),
            (.videos, ["mp4", "mov", "mkv"]), (.audio, ["mp3", "wav", "m4a", "flac"]),
            (.archives, ["zip", "gz", "tar", "7z", "rar"]), (.installers, ["dmg", "pkg"]),
            (.documents, ["pdf", "docx", "xlsx", "pptx", "txt", "md", "csv"]),
            (.code, ["swift", "py", "js", "ts", "json", "html", "css"])
        ]
        return groups.first { $0.1.contains(ext) }?.0
    }
}
