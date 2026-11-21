#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

cache_root="$project_dir/.build"
export CLANG_MODULE_CACHE_PATH="$cache_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

args=(
    --cache-path "$cache_root/spm-cache"
    --config-path "$cache_root/spm-config"
    --security-path "$cache_root/spm-security"
    --manifest-cache local
)

if ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
    args+=(--disable-sandbox)
fi

dev_dir="$(xcode-select -p)"
testing_plugin="$dev_dir/usr/lib/swift/host/plugins/testing"

if [[ "$dev_dir" == "/Library/Developer/CommandLineTools" && -d "$testing_plugin" ]]; then
    args+=(--disable-xctest -Xswiftc -plugin-path -Xswiftc "$testing_plugin")
fi

exec swift test "${args[@]}" "$@"
