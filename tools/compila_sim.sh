#!/bin/bash
# Compila per il simulatore (senza firma) e installa nel simulatore avviato.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project SaluteLibera.xcodeproj -scheme SaluteLibera \
  -destination "platform=iOS Simulator,name=${SIM_DEVICE:-iPhone 17 Pro}" \
  -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|warning: [^M]|BUILD (SUCCEEDED|FAILED)" | grep -v appintents | sort -u
TMPAPP="${TMPDIR:-/tmp}/salutelibera-sim/SaluteLibera.app"
rm -rf "$TMPAPP"; mkdir -p "$(dirname "$TMPAPP")"
cp -R build/DD/Build/Products/Debug-iphonesimulator/SaluteLibera.app "$TMPAPP"
xcrun simctl install "${SIM_DEVICE:-iPhone 17 Pro}" "$TMPAPP" && echo "installata"
