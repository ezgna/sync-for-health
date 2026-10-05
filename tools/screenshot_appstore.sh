#!/bin/bash
# Screenshot App Store di Sync for Health: modalità -demo (dati sintetici), IT e EN, 6,9" e 6,5".
# Uso: tools/screenshot_appstore.sh   (dopo una build Debug per simulatore in build/DD)
set -u
cd "$(dirname "$0")/.."
OUTROOT=docs/appstore/screenshots
DEVS=("iPhone 17 Pro Max:6.9" "SFH 6.5:6.5")
COMMON=(-demo -onboardingCompletato YES)
for d in "${DEVS[@]}"; do
  DEV="${d%%:*}"; SIZE="${d##*:}"
  for L in it en; do
    if [ "$L" = it ]; then LANGARGS=(-AppleLanguages "(it)" -AppleLocale it_IT); else LANGARGS=(-AppleLanguages "(en)" -AppleLocale en_US); fi
    OUT="$OUTROOT/$L/$SIZE"; mkdir -p "$OUT"
    export SIM_DEVICE="$DEV"
    SKIP_INSTALL=0 WAIT=16 tools/screenshot.sh "$OUT/01-oggi.png" light "${COMMON[@]}" "${LANGARGS[@]}" -tab oggi
    export SKIP_INSTALL=1
    WAIT=5 tools/screenshot.sh "$OUT/02-storico.png" light "${COMMON[@]}" "${LANGARGS[@]}" -tab oggi -autoSync
    tools/screenshot.sh "$OUT/03-gruppi.png" light -demo -onboarding -pagina 2 "${LANGARGS[@]}"
    tools/screenshot.sh "$OUT/04-privacy.png" light -demo -onboarding -pagina 1 "${LANGARGS[@]}"
    tools/screenshot.sh "$OUT/05-ecg.png" dark "${COMMON[@]}" "${LANGARGS[@]}" -tab oggi -fondo
    tools/screenshot.sh "$OUT/06-invii.png" light "${COMMON[@]}" "${LANGARGS[@]}" -tab invii
    tools/screenshot.sh "$OUT/07-impostazioni.png" light "${COMMON[@]}" "${LANGARGS[@]}" -tab impostazioni
    unset SKIP_INSTALL
  done
  xcrun simctl ui "$DEV" appearance light
  xcrun simctl shutdown "$DEV" 2>/dev/null || true
done
# App Store Connect rifiuta i PNG con canale alfa: controllo e dimensioni
for f in $(find "$OUTROOT" -name "*.png" | sort); do
  echo "$f $(sips -g pixelWidth -g pixelHeight -g hasAlpha "$f" | awk 'NR>1{printf "%s ", $2}')"
done
