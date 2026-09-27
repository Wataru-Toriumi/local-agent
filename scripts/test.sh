#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export SEIRI_WITHOUT_COREAI=1
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
# The dependency-free manifest must not discard the production lockfile.
if [ -f Package.resolved ]; then
    mkdir -p .build
    resolved_backup=$(mktemp .build/resolved.XXXXXX)
    cp Package.resolved "$resolved_backup"
    trap 'cp "$resolved_backup" Package.resolved; rm -f "$resolved_backup"' EXIT
fi
swift run --scratch-path .build/offline --cache-path .build/cache --disable-sandbox SeiriChecks
swift build --product seiri --scratch-path .build/offline --cache-path .build/cache --disable-sandbox
python3 scripts/smoke.py .build/offline/debug/seiri
