#!/usr/bin/env python3
"""Exercise the CLI with disposable files; never touches the user's documents."""
import json
import pathlib
import subprocess
import sys
import tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())


def run(*args, ok=True):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    return result


with tempfile.TemporaryDirectory(prefix="seiri-smoke-") as temp:
    base = pathlib.Path(temp)
    root = base / "Inbox"
    root.mkdir()
    originals = {"会議資料.txt": "次回の打ち合わせ", "photo.png": "image fixture"}
    for name, content in originals.items():
        (root / name).write_text(content)
    plan = base / "plan.json"
    run("--help")
    run("doctor")
    run("plan", root, "--mode", "downloads", "--rules-only", "--out", plan)
    document = json.loads(plan.read_text())
    assert len(document["moves"]) == 2
    assert all((root / name).exists() for name in originals)
    run("apply", plan)
    assert (root / "documents" / "会議資料.txt").exists()
    assert (root / "images" / "photo.png").exists()
    run("undo", str(plan) + ".journal.json")
    for name, content in originals.items():
        assert (root / name).read_text() == content
    run("apply", plan, ok=False)  # history is never overwritten
    run("plan", root, "--mode", "downloads", "--rules-only", "--out", plan, ok=False)
    run("plan", root, "--mode", "work", "--model", base / "missing-model", "--out", base / "ai.json", ok=False)
    assert not (base / "ai.json").exists()  # no silent fallback from Core AI
    run("plan", root, "--mode", "invalid", "--rules-only", "--out", base / "bad.json", ok=False)
    run("undo", str(plan) + ".journal.json", "--unknown", ok=False)
print("CLI smoke checks passed")
