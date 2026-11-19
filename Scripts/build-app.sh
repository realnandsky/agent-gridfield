#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

output_dir="${1:-"$project_dir/dist"}"
mkdir -p "$output_dir"
build_dir="$(mktemp -d "$output_dir/.gridworld-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"

swiftc -swift-version 6 -O -whole-module-optimization -parse-as-library \
    -module-name GridWorld -target arm64-apple-macosx14.0 -sdk "$sdk" \
    -module-cache-path "$build_dir/cache" Sources/GridWorld/*.swift -o "$build_dir/GridWorld"

app="$output_dir/GridWorld.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$build_dir/GridWorld" "$app/Contents/MacOS/GridWorld"
install -m 644 Bundle/Info.plist "$app/Contents/Info.plist"
install -m 644 Bundle/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
install -m 644 LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
