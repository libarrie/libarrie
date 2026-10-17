#!/usr/bin/env bash
# Builds LibarrieKit and LibarrieUI for macOS and runs the unit tests. Works
# with Xcode or with only the Command Line Tools (which need the Swift
# Testing macro plugin path passed explicitly).
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if ! xcode-select -p 2>/dev/null | grep -q Xcode.app && [ -d "$plugins" ]; then
  args=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
swift build "${args[@]}"
swift test "${args[@]}"
