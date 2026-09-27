#!/bin/sh
# Build and link the development CLI into a directory on PATH.
set -eu

usage() {
    printf 'Usage: %s [--bin-dir DIRECTORY]\n' "$0"
    printf 'Default: $HOME/.local/bin\n'
}

seiri_bin_dir="$HOME/.local/bin"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bin-dir)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then usage >&2; exit 1; fi
            seiri_bin_dir="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
# Resolve a relative destination before changing to the project directory.
case "$seiri_bin_dir" in
    /*) ;;
    *) seiri_bin_dir="$PWD/$seiri_bin_dir" ;;
esac
cd "$(dirname "$0")/.."
unset SEIRI_WITHOUT_COREAI
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --product seiri --cache-path .build/cache
seiri_build_dir=$(swift build -c release --show-bin-path --cache-path .build/cache)
seiri_source="$seiri_build_dir/seiri"
seiri_destination="$seiri_bin_dir/seiri"

if [ ! -x "$seiri_source" ]; then
    printf 'Executable not found: %s\n' "$seiri_source" >&2
    exit 1
fi
mkdir -p "$seiri_bin_dir"
if [ -e "$seiri_destination" ] || [ -L "$seiri_destination" ]; then
    if [ ! -L "$seiri_destination" ] || [ "$(readlink "$seiri_destination")" != "$seiri_source" ]; then
        printf 'Refusing to replace an existing command: %s\n' "$seiri_destination" >&2
        exit 1
    fi
else
    ln -s "$seiri_source" "$seiri_destination"
fi
printf 'Installed: %s -> %s\n' "$seiri_destination" "$seiri_source"
case ":$PATH:" in
    *":$seiri_bin_dir:"*) ;;
    *) printf 'Add this directory to your shell PATH: %s\n' "$seiri_bin_dir" ;;
esac
