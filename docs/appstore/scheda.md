# Sync for Health — scheda App Store (IT / EN)

Testi pronti da incollare in App Store Connect. Lunghezze controllate con tools/controlla_scheda.py
(nome ≤ 30, sottotitolo ≤ 30, parole chiave ≤ 100 byte, testo promozionale ≤ 170, descrizione ≤ 4000).
Ogni affermazione è verificata nel codice (vedi «Verifiche» in fondo). Nessuna altra app è nominata (linee guida 2.3.7).

## Dati generali (uguali per tutte le lingue)

| Campo | Valore |
|---|---|
| Nome | Sync for Health |
| Bundle ID | it.vcnngr.syncforhealth |
| SKU | syncforhealth-ios-1 |
| Versione | 1.0 (build 1) |
| Categoria principale | Salute e fitness (Health & Fitness) |
| Categoria secondaria | Utility (facoltativa) |
| Prezzo | Gratis, nessun acquisto in-app |
| Disponibilità | tutti i paesi |
| Requisiti | iPhone con iOS 26 o successivo |
| Copyright | © 2026 Vincenzo Ingrosso |
| URL assistenza | https://vcnngr.github.io/sync-for-health/ |
| URL marketing | https://github.com/vcnngr/sync-for-health |
| URL privacy | https://vcnngr.github.io/sync-for-health/privacy.html |
| App Privacy | Data Not Collected / Dati non raccolti |
| Crittografia (export compliance) | Usa solo HTTPS di sistema → ITSAppUsesNonExemptEncryption = NO; rispondere «No» alla domanda sugli algoritmi non esenti |

### Classificazione per età (questionario 2025) → 4+
Tutte le voci «Nessuno/No»: violenza, temi per adulti, linguaggio, gioco d'azzardo, contenuti generati dagli utenti,
messaggistica e chat, pubblicità, controlli parentali, accesso web libero. «Informazioni mediche o di trattamento»: Nessuna
(l'app mostra i dati dell'utente, non dà consigli medici). Se compare la domanda «Temi di salute o benessere»: Sì
(rimane 4+). Risultato atteso: 4+.

### Note per il revisore (App Review Information › Notes)
Non servono credenziali: l'app non ha account.

EN (da incollare):
Sync for Health reads the HealthKit data the user authorizes and sends it only to an HTTPS server the user enters
(self-hosted). There is no developer server, no account, no analytics, no ads, no third-party SDK, no iCloud.
To review without a server: on the first screen tap "No server? Try with sample data" (or Settings › Demo mode).
Demo mode shows synthetic data and simulated syncs; no real Health data is read or sent.
To test a real sync you can run the receiver in the open-source repo (tools/ricevitore_prova.py) and enter its URL.
Permissions are requested per group (Activity, Heart, Sleep…); nothing is preselected and GPS workout routes are off by default.
The app is read-only: it never writes to Health. Contact: expert@slackarea.net (subject starting with "Sync for Health").

Contatto per la revisione: nome Vincenzo Ingrosso, mail expert@slackarea.net, telefono → da inserire a mano da Vincenzo
(App Store Connect lo chiede, non viene pubblicato).

---

## Italiano (it)

**Nome:** Sync for Health

**Sottotitolo (≤ 30):**
Tutta Salute sul tuo server

**Testo promozionale (≤ 170):**
Oltre 190 tipi di dati di Salute, ECG compresi, e tutto lo storico, inviati al tuo server. Gratis, a codice aperto, senza account né intermediari.

**Parole chiave (≤ 100 byte, IT):**
esporta,salute,healthkit,ecg,webhook,json,server,backup,storico,privacy,api,open source,gratis,dati

**Descrizione:**
Sync for Health porta i tuoi dati di Salute sul server che scegli tu: un piccolo computer di casa, il tuo cloud, il tuo sistema di analisi. Senza account, senza abbonamenti e senza passare da nessun server dello sviluppatore.

TUTTI I TUOI DATI
• Oltre 190 tipi di dati di Salute: passi, battito, variabilità cardiaca, sonno con le fasi, respirazione, peso e composizione corporea, nutrizione, glicemia, udito, mindfulness, ciclo, sintomi e altro.
• Elettrocardiogrammi con il tracciato completo, non solo la classificazione.
• Allenamenti, audiogrammi e stato d'animo. Percorsi GPS solo se li accendi tu.

TUTTO LO STORICO
• Il primo invio porta anni di dati, a blocchi.
• Se si interrompe, riprende da dove si era fermato: un blocco conta come inviato solo quando il tuo server conferma.
• Vedi l'avanzamento passo per passo: «tipo N di M», campioni e blocchi.
• Poi invia solo le novità, comprese le cancellazioni, anche in background quando Salute registra nuovi dati.

SCEGLI TU COSA CONDIVIDERE
• I permessi si danno per gruppi (attività, cuore, sonno, ECG…). Nessun gruppo è scelto in partenza.
• Puoi aggiungere altri gruppi quando vuoi; Salute ti chiede conferma solo per i tipi nuovi.

PRIVACY, DAVVERO
• I dati vanno solo all'indirizzo che inserisci. Lo sviluppatore non riceve nulla: non esiste un server di Sync for Health.
• Nessuna pubblicità, nessuna analisi, nessun SDK di terze parti, nessun iCloud.
• Collegamento HTTPS, token facoltativo custodito nel Portachiavi.
• L'app legge soltanto: non scrive mai in Salute.

GRATIS E A CODICE APERTO
• Gratis, senza acquisti in-app.
• Codice sorgente pubblico con licenza MIT e formato JSON documentato, così puoi costruire il tuo ricevitore in pochi minuti.

PROVALA SUBITO
Non hai ancora un server? Apri la modalità dimostrativa: dati di esempio inventati, per vedere come funziona senza inviare nulla.

Serve un server HTTPS che riceva richieste POST in JSON. Sync for Health non offre un servizio di archiviazione e non fornisce consigli medici.

**Novità di questa versione:** Prima versione.

---

## English (en-US)

**Name:** Sync for Health

**Subtitle (≤ 30):**
All Health data to your server

**Promotional text (≤ 170):**
190+ Health data types, ECG included, and your full history, sent to your own server. Free, open source, no account and no middleman.

**Keywords (≤ 100 bytes, EN):**
export,healthkit,ecg,webhook,json,self-hosted,backup,history,privacy,api,open source,free,server,ios

**Description:**
Sync for Health sends your Health data to a server you choose: a small computer at home, your own cloud, your analytics stack. No account, no subscription, and no developer server in between.

ALL YOUR DATA
• 190+ Health data types: steps, heart rate, heart rate variability, sleep with stages, respiration, weight and body composition, nutrition, blood glucose, hearing, mindfulness, cycle tracking, symptoms and more.
• Electrocardiograms with the full waveform, not just the classification.
• Workouts, audiograms and state of mind. GPS routes only if you turn them on.

YOUR FULL HISTORY
• The first sync sends years of data, in batches.
• If it is interrupted, it resumes where it stopped: a batch counts as sent only after your server confirms it.
• Follow the progress step by step: "type N of M", samples and batches.
• Afterwards it sends only what's new, deletions included, also in the background when Health records new data.

YOU CHOOSE WHAT TO SHARE
• Permissions are granted by group (activity, heart, sleep, ECG…). No group is selected by default.
• Add more groups any time; Health asks only for the new types.

PRIVACY, FOR REAL
• Data goes only to the address you enter. The developer receives nothing: there is no Sync for Health server.
• No ads, no analytics, no third-party SDKs, no iCloud.
• HTTPS connection, optional token stored in the Keychain.
• Read-only: the app never writes to Health.

FREE AND OPEN SOURCE
• Free, with no in-app purchases.
• Public source code under the MIT license and a documented JSON format, so you can build your own receiver in minutes.

TRY IT NOW
No server yet? Open demo mode: made-up sample data, to see how it works without sending anything.

Requires an HTTPS server that accepts JSON POST requests. Sync for Health is not a storage service and does not provide medical advice.

**What's New:** First release.

---

## Screenshot (docs/appstore/screenshots/{it,en}/{6.9,6.5}/, PNG senza alfa)

| File | Mostra | Punto di forza |
|---|---|---|
| 01-oggi | numeri del giorno, ultimo ECG | tutto, ECG |
| 02-storico | primo invio in corso «tipo N di M» | tutto lo storico, ripresa |
| 03-gruppi | scelta dei gruppi, nessuno preselezionato | scegli tu |
| 04-privacy | pagina privacy dell'introduzione | solo il tuo server |
| 05-ecg | tracciato ECG (tema scuro) | ECG completo |
| 06-invii | registro degli invii | affidabilità |
| 07-impostazioni | indirizzo, token, gruppi | nessun account |

6,9": 1320×2868 (iPhone 17 Pro Max). 6,5": 1284×2778 (iPhone 14 Plus). Tutte in modalità -demo, dati sintetici.

## Verifiche nel codice (perché ogni frase è vera)
- «Oltre 190 tipi»: il catalogo contiene 192 voci (119 quantità, 69 categorie, allenamenti, ECG, audiogrammi, stato d'animo); su iOS 26.3 ne risultano disponibili 191.
- «Tracciato completo ECG»: HKElectrocardiogramQuery, ~15 000 valori in µV per ECG, POST dedicati.
- «Tutto lo storico / riprende»: HKAnchoredObjectQuery a blocchi da 5000; l'ancora viene salvata solo dopo una risposta 2xx.
- «tipo N di M»: mostrato in Oggi durante l'invio.
- «In background»: HKObserverQuery + enableBackgroundDelivery, BGAppRefreshTask/BGProcessingTask.
- «Solo al tuo server / Data Not Collected»: l'unica rete è URLSession verso l'indirizzo impostato dall'utente (dati e diagnostica); nessun SDK, nessun iCloud, nessun dominio dello sviluppatore nel codice.
- «Non scrive in Salute»: solo permessi di lettura (toShare vuoto).
- «Gratis, MIT»: licenza nel file LICENSE del repo pubblico.

## Proposte per la 1.1 (non bloccano la 1.0)
- Più destinazioni (più webhook): stimato 1–2 giorni (impostazioni a lista, ancore per destinazione, interfaccia).
- Registro con pulsante «Riprova» per il singolo invio fallito: stimato mezza giornata (l'app già riprende da sola; il pulsante rilancia l'invio dal punto salvato).
