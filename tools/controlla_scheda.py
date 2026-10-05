#!/usr/bin/env python3
"""Controlla le lunghezze dei campi della scheda App Store in docs/appstore/scheda.md."""
import re, sys, pathlib

testo = pathlib.Path(__file__).resolve().parent.parent.joinpath("docs/appstore/scheda.md").read_text()
LIMITI = {"Sottotitolo": 30, "Subtitle": 30, "Testo promozionale": 170, "Promotional text": 170,
          "Parole chiave": 100, "Keywords": 100}
ok = True
for etichetta, limite in LIMITI.items():
    m = re.search(r"\*\*" + re.escape(etichetta) + r"[^*]*\*\*\n(.+)\n", testo)
    if not m:
        print("manca", etichetta); ok = False; continue
    valore = m.group(1).strip()
    n = len(valore.encode()) if etichetta in ("Parole chiave", "Keywords") else len(valore)
    stato = "ok" if n <= limite else "TROPPO LUNGO"
    ok &= n <= limite
    print(f"{etichetta}: {n}/{limite} {stato}")
for titolo in ("## Italiano", "## English"):
    blocco = testo.split(titolo, 1)[1]
    desc = re.search(r"\*\*(Descrizione|Description):\*\*\n(.+?)\n\*\*", blocco, re.S).group(2).strip()
    print(f"descrizione {titolo[3:]}: {len(desc)}/4000", "ok" if len(desc) <= 4000 else "TROPPO LUNGA")
    ok &= len(desc) <= 4000
print("nome:", len("Sync for Health"), "/30")
sys.exit(0 if ok else 1)
