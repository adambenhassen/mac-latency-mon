#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="LatencyMon.app"

swiftc -O main.swift -o LatencyMon

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp LatencyMon "$APP/Contents/MacOS/LatencyMon"
cp Info.plist "$APP/Contents/Info.plist"
rm -f LatencyMon

echo "Built $APP — run:  open $APP"
