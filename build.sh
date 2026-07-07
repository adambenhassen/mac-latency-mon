#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="LatencyMon.app"
TARGET="13.0"

# Universal binary: compile both arches, then lipo them together.
swiftc -O main.swift -o LatencyMon-arm64  -target arm64-apple-macosx$TARGET
swiftc -O main.swift -o LatencyMon-x86_64 -target x86_64-apple-macosx$TARGET
lipo -create LatencyMon-arm64 LatencyMon-x86_64 -output LatencyMon
rm -f LatencyMon-arm64 LatencyMon-x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp LatencyMon "$APP/Contents/MacOS/LatencyMon"
cp Info.plist "$APP/Contents/Info.plist"
rm -f LatencyMon

echo "Built universal $APP ($(lipo -archs "$APP/Contents/MacOS/LatencyMon")) — run:  open $APP"
