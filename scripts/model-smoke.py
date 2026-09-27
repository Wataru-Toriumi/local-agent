#!/usr/bin/env python3
"""Run the real Core AI backend on disposable Japanese documents, then round-trip."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import time

binary = str(pathlib.Path(sys.argv[1]).resolve())
model = str(pathlib.Path(sys.argv[2]).resolve())
fixtures = {
    "work": {
        "sample-a.txt": ("請求書\n請求先：テスト株式会社\n件名：9月分システム保守費用\n請求金額：55,000円\nお支払期限：2026年10月31日", "invoices"),
        "sample-b.txt": ("定例会議 議事録\n日時：2026年9月20日\n参加者：田中、佐藤\n議題：新機能の開発計画\n決定事項：来週に試作品を確認する。\n担当：田中が画面案を作成する。", "meetings"),
        "sample-c.txt": ("業務委託契約書\n株式会社テスト（甲）と株式会社サンプル（乙）は、以下のとおり契約を締結する。\n第1条 委託業務：ウェブサイトの保守。\n第2条 契約期間：2026年10月1日から2027年9月30日。\n第3条 甲乙は業務上知り得た秘密を第三者に開示しない。", "contracts"),
    },
    "downloads": {
        "notes.txt": ("出張準備のメモ", "documents"),
        "example.py": ("print('hello')\n", "code"),
    },
}


def run(*args):
    result = subprocess.run([binary, *map(str, args)], text=True, capture_output=True, timeout=600)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="seiri-model-check-") as temp:
    base = pathlib.Path(temp)
    for mode, files in fixtures.items():
        root = base / mode
        root.mkdir()
        hashes = {}
        for name, (content, _) in files.items():
            data = content.encode()
            (root / name).write_bytes(data)
            hashes[name] = hashlib.sha256(data).hexdigest()
        plan = base / f"{mode}.json"
        print(run("plan", root, "--mode", mode, "--model", model, "--out", plan), flush=True)
        moves = json.loads(plan.read_text())["moves"]
        actual = {entry["name"]: entry["category"] for entry in moves}
        expected = {name: category for name, (_, category) in files.items()}
        assert actual == expected, f"Classification mismatch: {actual} != {expected}"
        run("apply", plan)
        for entry in moves:
            destination = root / entry["category"] / entry["name"]
            assert hashlib.sha256(destination.read_bytes()).hexdigest() == hashes[entry["name"]]
        run("undo", str(plan) + ".journal.json")
        for name, digest in hashes.items():
            assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
        backend = "Qwen inference" if mode == "work" else "extension rules"
        print(f"{mode}: {backend} + apply + undo passed", flush=True)
print(f"Core AI smoke checks passed ({time.monotonic() - started:.1f}s)")
