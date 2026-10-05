#!/usr/bin/env python3
"""Ricevitore di prova per Salute Libera.

Ascolta in HTTP, accetta i POST dell'app, controlla la forma del payload
(docs/PROTOCOL.md), stampa un riepilogo e salva ogni corpo ricevuto in
./ricevuti/ come JSON. Solo libreria standard.

Uso:
    python3 tools/ricevitore_prova.py [--porta 8787] [--token SEGRETO] [--cartella ricevuti]

Nel simulatore iOS, 127.0.0.1 è il Mac stesso: imposta come destinazione
    http://127.0.0.1:8787/salute
(L'app accetta http solo per indirizzi locali; altrove serve https.)
"""
import argparse
import datetime as dt
import gzip
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SEZIONI = {"campioni", "categorie", "allenamenti", "ecg", "audiogrammi",
           "stati_d_animo", "eliminati", "caratteristiche"}
CAMPI = {
    "campioni": {"uuid", "tipo", "valore", "unita", "inizio", "fine", "fonte"},
    "categorie": {"uuid", "tipo", "valore", "inizio", "fine", "fonte"},
    "allenamenti": {"uuid", "attivita", "inizio", "fine", "durata_s", "fonte"},
    "ecg": {"uuid", "inizio", "classificazione"},
    "audiogrammi": {"uuid", "inizio", "fine", "fonte", "punti"},
    "stati_d_animo": {"uuid", "inizio", "tipo", "valenza", "classificazione"},
}


def controlla(doc):
    """Ritorna una lista di problemi (vuota se il payload è conforme)."""
    problemi = []
    if doc.get("app") != "salute-libera":
        problemi.append("campo 'app' mancante o diverso da 'salute-libera'")
    if doc.get("versione") != 1:
        problemi.append("campo 'versione' mancante o diverso da 1")
    if doc.get("prova"):
        return problemi
    if "diagnostica" in doc:
        d = doc["diagnostica"]
        for chiave in ("versione_app", "build", "ios", "righe"):
            if chiave not in d:
                problemi.append(f"diagnostica senza '{chiave}'")
        if len(d.get("righe", [])) > 300:
            problemi.append("diagnostica con più di 300 righe")
        return problemi
    for chiave in ("dispositivo", "inviato"):
        if chiave not in doc:
            problemi.append(f"campo '{chiave}' mancante")
    try:
        dt.datetime.fromisoformat(doc.get("inviato", ""))
    except ValueError:
        problemi.append("'inviato' non è ISO 8601")
    sconosciute = set(doc) - SEZIONI - {"app", "versione", "dispositivo", "inviato"}
    if sconosciute:
        problemi.append(f"sezioni sconosciute: {sorted(sconosciute)}")
    for sezione, richiesti in CAMPI.items():
        for i, rec in enumerate(doc.get(sezione, []) or []):
            mancanti = richiesti - set(rec)
            if mancanti:
                problemi.append(f"{sezione}[{i}] senza {sorted(mancanti)}")
                break
    ecg = doc.get("ecg") or []
    if len(ecg) > 5:
        problemi.append(f"{len(ecg)} ECG in un solo POST (massimo 5)")
    for i, e in enumerate(ecg):
        if "tracciato" in e:
            if e.get("unita_tracciato") != "µV" or not e.get("frequenza_hz"):
                problemi.append(f"ecg[{i}]: tracciato senza 'unita_tracciato' µV o 'frequenza_hz'")
            elif not all(isinstance(v, (int, float)) for v in e["tracciato"]):
                problemi.append(f"ecg[{i}]: tracciato con valori non numerici")
    if ecg and any(k in doc for k in ("campioni", "categorie", "allenamenti")):
        problemi.append("ECG nello stesso POST di altri campioni (dovrebbero viaggiare a parte)")
    for sezione in SEZIONI:
        if sezione in doc and doc[sezione] in ([], {}, None):
            problemi.append(f"sezione '{sezione}' presente ma vuota (andrebbe omessa)")
    return problemi


class Gestore(BaseHTTPRequestHandler):
    token = None
    cartella = "ricevuti"

    def _rispondi(self, codice, corpo):
        dati = json.dumps(corpo).encode()
        self.send_response(codice)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(dati)))
        self.end_headers()
        self.wfile.write(dati)

    def do_POST(self):
        if self.token:
            auth = self.headers.get("Authorization", "")
            query = parse_qs(urlparse(self.path).query)
            if auth != f"Bearer {self.token}" and query.get("t", [None])[0] != self.token:
                print("  ✗ token mancante o errato")
                return self._rispondi(401, {"errore": "token"})
        corpo = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        compresso = self.headers.get("Content-Encoding") == "gzip"
        if compresso:
            corpo = gzip.decompress(corpo)
        try:
            doc = json.loads(corpo)
        except json.JSONDecodeError as e:
            print(f"  ✗ JSON non valido: {e}")
            return self._rispondi(400, {"errore": "json"})

        ora = dt.datetime.now().strftime("%H:%M:%S")
        if doc.get("prova"):
            print(f"[{ora}] prova di connessione ricevuta ✓")
        elif "diagnostica" in doc:
            d = doc["diagnostica"]
            print(f"[{ora}] diagnostica v{d.get('versione_app')} ({d.get('build')}) iOS {d.get('ios')} · "
                  f"{len(d.get('righe', []))} righe")
            for riga in d.get("righe", [])[-6:]:
                print(f"    | {riga}")
        else:
            conteggi = ", ".join(f"{k}={len(v) if isinstance(v, list) else 1}"
                                 for k, v in doc.items() if k in SEZIONI)
            print(f"[{ora}] {doc.get('dispositivo')} · {len(corpo):,} byte"
                  f"{' (gzip)' if compresso else ''} · {conteggi}")
            tipi = {}
            for rec in doc.get("campioni", []):
                tipi[(rec["tipo"], rec["unita"])] = tipi.get((rec["tipo"], rec["unita"]), 0) + 1
            for (tipo, unita), n in sorted(tipi.items()):
                print(f"    {n:5d} × {tipo.replace('HKQuantityTypeIdentifier', '')} [{unita}]")
            for e in doc.get("ecg", []) or []:
                tr = e.get("tracciato") or []
                print(f"    ECG {e.get('inizio')} · {e.get('classificazione')} · "
                      f"{len(tr):,} valori a {e.get('frequenza_hz')} Hz [{e.get('unita_tracciato')}]")
        problemi = controlla(doc)
        for p in problemi:
            print(f"  ⚠ {p}")
        if not problemi:
            print("  ✓ payload conforme a docs/PROTOCOL.md")

        os.makedirs(self.cartella, exist_ok=True)
        nome = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".json"
        with open(os.path.join(self.cartella, nome), "w") as f:
            json.dump(doc, f, indent=2, ensure_ascii=False)
        self._rispondi(200, {"ok": True, "problemi": problemi})

    def log_message(self, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--porta", type=int, default=8787)
    ap.add_argument("--token", help="se impostato, richiede Bearer o ?t=")
    ap.add_argument("--cartella", default="ricevuti")
    a = ap.parse_args()
    Gestore.token, Gestore.cartella = a.token, a.cartella
    print(f"In ascolto su http://0.0.0.0:{a.porta}/ — Ctrl+C per uscire")
    try:
        ThreadingHTTPServer(("0.0.0.0", a.porta), Gestore).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
