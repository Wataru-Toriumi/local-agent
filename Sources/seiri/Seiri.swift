import Foundation
import SeiriCore
import Darwin

@main struct Seiri {
    static let help = """
    seiri — Qwen + Core AIでローカルのファイルを整理

      seiri plan FOLDER --mode downloads|work --model MODEL_FOLDER --out PLAN.json
      seiri plan FOLDER --mode downloads --rules-only --out PLAN.json
      seiri apply PLAN.json [--journal JOURNAL.json]
      seiri undo JOURNAL.json
      seiri doctor

    planは対象直下の通常ファイルを読み、整理案を表示・保存します（移動なし）。
    applyは分類名のサブフォルダへ移動します。削除・上書き・再帰走査はしません。
    undoは実行履歴から元の場所へ戻します。整理案と履歴は対象フォルダの外に保存してください。
    --rules-onlyは拡張子だけで分類する動作確認用です。Qwenは使用しません。
    """
    @MainActor static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("エラー: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    @MainActor static func run(_ args: [String]) async throws {
        guard let command = args.first else { print(help); return }
        if command == "--help" || command == "help" { print(help); return }
        if command == "doctor" {
            guard args.count == 1 else { throw SeiriError("doctorに引数は不要です") }
            print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            #if WITHOUT_COREAI
            print("Core AI: 無効な開発ビルド。Xcode 27を選択し、SEIRI_WITHOUT_COREAIを外して再ビルドしてください。")
            #else
            print("Core AI: 有効。planには変換済みQwenのリソースフォルダが必要です。")
            #endif
            return
        }
        guard args.count >= 2, !args[1].hasPrefix("--") else { throw SeiriError(help) }
        let input = url(args[1])
        var options: [String: String] = [:]
        var rulesOnly = false
        var index = 2
        while index < args.count {
            let key = args[index]
            if key == "--rules-only" {
                guard !rulesOnly else { throw SeiriError("--rules-onlyが重複しています") }
                rulesOnly = true; index += 1; continue
            }
            guard ["--mode", "--model", "--out", "--journal"].contains(key),
                  options[key] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw SeiriError("不正な引数: \(key)\n\(help)")
            }
            options[key] = args[index + 1]; index += 2
        }
        switch command {
        case "plan":
            guard options["--journal"] == nil,
                  let modeText = options["--mode"], let mode = Mode(rawValue: modeText),
                  let outputPath = options["--out"] else { throw SeiriError(help) }
            let output = url(outputPath)
            try FileSafety.requireOutside(output, root: input)
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SeiriError("整理案が既に存在します: \(output.path)") }
            let classifier: any Classifier
            if rulesOnly {
                guard options["--model"] == nil else { throw SeiriError("--rules-onlyと--modelは同時に指定できません") }
                classifier = RulesClassifier()
            } else {
                guard let modelPath = options["--model"] else { throw SeiriError("--modelに変換済みQwenのリソースフォルダを指定してください") }
                #if WITHOUT_COREAI
                _ = modelPath
                throw SeiriError("この開発ビルドではCore AIを利用できません。READMEのXcode 27セットアップを実施してください。")
                #else
                classifier = try await CoreAIClassifier(resourcesAt: url(modelPath))
                #endif
            }
            let plan = try await Planner().make(root: input, mode: mode, classifier: classifier)
            for move in plan.moves {
                // JSON escaping prevents filenames and model text from injecting terminal control sequences.
                let encoded = try JSONEncoder().encode(["from": move.name, "to": move.destination, "reason": move.reason, "extraction": move.extraction])
                print(String(decoding: encoded, as: UTF8.self))
            }
            try JSONFile.write(plan, to: output, new: true)
            print("整理案: \(output.path)（\(plan.moves.count)件、移動は未実行）")
        case "apply":
            guard !rulesOnly, options.keys.allSatisfy({ $0 == "--journal" }) else { throw SeiriError(help) }
            let journalURL = options["--journal"].map(url) ?? url(input.path + ".journal.json")
            let plan = try JSONFile.read(Plan.self, from: input)
            try FileOperations().apply(plan, journalURL: journalURL)
            print("\(plan.moves.count)件を移動しました。履歴: \(journalURL.path)")
        case "undo":
            guard !rulesOnly, options.isEmpty else { throw SeiriError(help) }
            try FileOperations().undo(journalURL: input)
            print("取り消しが完了しました。分類先の空フォルダは残ります。")
        default: throw SeiriError("不明なコマンド: \(command)\n\(help)")
        }
    }
}
