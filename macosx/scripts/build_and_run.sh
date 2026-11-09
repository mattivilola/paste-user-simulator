#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project PasteUserSimulator.xcodeproj -scheme PasteUserSimulator \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build/packages build

app="$PWD/.build/xcode/Build/Products/Debug/Paste User Simulator.app"
process="$app/Contents/MacOS/Paste User Simulator"
while IFS= read -r pid; do
    if [[ "$(ps -p "$pid" -o comm=)" == "$process" ]]; then
        kill -TERM "$pid"
    fi
done < <(pgrep -f 'Paste User Simulator.app/Contents/MacOS/Paste User Simulator' || true)
open -n "$app"
