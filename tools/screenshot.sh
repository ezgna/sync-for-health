#!/bin/bash
# Avvia l'app nel simulatore con argomenti e salva uno screenshot.
# Uso: tools/screenshot.sh <file.png> <light|dark> [argomenti di avvio...]
# Esempio: tools/screenshot.sh docs/screenshots/oggi-chiaro.png light -demo -tab oggi
set -euo pipefail
OUT="$1"; MODE="$2"; shift 2
DEV="${SIM_DEVICE:-iPhone 17 Pro}"
BUNDLE=${BUNDLE:-it.vcnngr.syncforhealth}
APP="$(dirname "$0")/../build/DD/Build/Products/Debug-iphonesimulator/SaluteLibera.app"

xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl ui "$DEV" appearance "$MODE"
xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --operatorName "" >/dev/null 2>&1 || true
# CoreSimulator può bloccarsi leggendo da ~/Documents (permessi macOS): installa da una copia temporanea.
TMPAPP="${TMPDIR:-/tmp}/syncforhealth-sim/SaluteLibera.app"
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
  rm -rf "$TMPAPP"; mkdir -p "$(dirname "$TMPAPP")"; cp -R "$APP" "$TMPAPP"
  xcrun simctl install "$DEV" "$TMPAPP"
fi
xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$DEV" "$BUNDLE" "$@" >/dev/null
sleep "${WAIT:-4}"
xcrun simctl io "$DEV" screenshot "$OUT" >/dev/null 2>&1
echo "salvato $OUT"
