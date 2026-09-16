#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="$(uname -m)-apple-macos13.0"
OUT="$(mktemp -d)/logic-tests"

echo "Kompilacja testów…"
xcrun swiftc -sdk "$SDK" -target "$TARGET" \
  "Tests/main.swift" \
  "Wokyintosh/SystemMonitor.swift" \
  "Wokyintosh/NowPlayingMonitor.swift" \
  -o "$OUT"

echo "Uruchamianie…"
"$OUT"
