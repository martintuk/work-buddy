#!/usr/bin/env bash
# Render the real SwiftUI panel with fictional data, without starting integrations.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/toolchain.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

SOURCES=()
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$ROOT/Sources/WorkBuddy" -name '*.swift' ! -name main.swift -print0)

swiftc -swift-version 6 -D DEBUG -parse-as-library "${SOURCES[@]}" \
    "$ROOT/scripts/screenshots.swift" -o "$SCRATCH/WorkBuddyScreenshots"
"$SCRATCH/WorkBuddyScreenshots" "${1:-$ROOT/docs/images}"
