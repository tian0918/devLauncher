#!/bin/zsh
set -eu

project_dir=${0:A:h:h}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/devlauncher-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

swiftc_bin="/usr/bin/swiftc"
extra_flags=()
if ! "$swiftc_bin" --version >/dev/null 2>&1; then
    for xcode_app in /Applications/Xcode*.app; do
        candidate="$xcode_app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        sdk="$xcode_app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        if [[ -x "$candidate" && -d "$sdk" ]]; then
            export DEVELOPER_DIR="$xcode_app/Contents/Developer"
            swiftc_bin="$candidate"
            extra_flags=(-sdk "$sdk" -disable-sandbox)
            break
        fi
    done
    if [[ "$swiftc_bin" == "/usr/bin/swiftc" && -x "/Library/Developer/CommandLineTools/usr/bin/swiftc" ]]; then
        export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
        swiftc_bin="/Library/Developer/CommandLineTools/usr/bin/swiftc"
        extra_flags=(-sdk "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" -disable-sandbox)
    fi
fi

# Typecheck the entire application target including all SwiftUI views.
"$swiftc_bin" "${extra_flags[@]}" -target arm64-apple-macos15.0 -parse-as-library -typecheck \
    -module-cache-path "$scratch/cache" \
    "$project_dir"/Sources/**/*.swift

# Build and run the headless unit & integration test suite (Models + Runtime + Integrations).
"$swiftc_bin" "${extra_flags[@]}" -target arm64-apple-macos15.0 -parse-as-library \
    -module-cache-path "$scratch/cache" \
    "$project_dir"/Sources/{Models,Runtime,Integrations}/*.swift \
    "$project_dir/Tests/Integration.swift" -o "$scratch/integration"
"$scratch/integration"
