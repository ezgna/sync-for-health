# Protocollo di invio — Salute Libera v1

Salute Libera invia i dati di Salute con richieste **HTTP POST** all'indirizzo configurato
dall'utente. Questo documento descrive tutto ciò che un server deve sapere per riceverli.

## Richiesta

| Elemento | Valore |
|---|---|
| Metodo | `POST` all'URL configurato, **usato così com'è** (eventuali parametri come `?t=SEGRETO` restano nella query) |
| `Content-Type` | `application/json; charset=utf-8` |
| `Authorization` | `Bearer <token>` — solo se l'utente ha inserito un token |
| `Content-Encoding` | `gzip` — solo se l'utente ha attivato la compressione (spenta di serie) |
| `User-Agent` | `SaluteLibera/<versione>` |
| Schema | `https://` ovunque; `http://` accettato solo verso indirizzi locali (localhost, `*.local`, 10/8, 172.16/12, 192.168/16) |

## Risposta attesa

- **2xx** (qualsiasi corpo): il blocco è considerato consegnato e l'app salva i segnalibri
  (ancore) dei tipi contenuti. Il blocco non verrà più reinviato.
- **408, 429, 5xx o errore di rete**: l'app ritenta fino a 4 volte con attesa crescente
  (2 s, 6 s, 18 s), poi rinuncia e riprova al giro successivo.
- **Altri 4xx**: nessun nuovo tentativo immediato; l'errore viene mostrato nel registro.

Finché il server non risponde 2xx **nessun dato viene considerato inviato**: al giro successivo
si riparte dallo stesso punto. Ne segue che il server può ricevere **duplicati** (per esempio se
ha salvato i dati ma la risposta si è persa): deduplica sempre per `uuid`.

## Prova di connessione

Il pulsante «Prova connessione» invia esattamente:

```json
{"app":"salute-libera","versione":1,"prova":true}
```

Rispondi 2xx per confermare. Non contiene dati.

## Diagnostica

Oltre ai dati, l'app invia allo **stesso indirizzo** (stesso token, stessa impostazione gzip)
un POST separato con le ultime righe del suo registro tecnico:

```json
{"app": "salute-libera", "versione": 1,
 "diagnostica": {
   "versione_app": "0.1.0", "build": "1", "ios": "26.3.1", "dispositivo": "iPhone17,1",
   "righe": [
     "2026-10-01T16:54:31.279+02:00 [INFO] [sync] inizio (manuale), gruppi: altro,attivita,corpo,cuore,mindfulness,respirazione,sonno,udito, gzip: no",
     "2026-10-01T16:54:41.319+02:00 [INFO] [rete] POST esempio.it 25158 byte → HTTP 200 in 58 ms, tentativo 1/4",
     "2026-10-01T16:54:41.359+02:00 [INFO] [sync] fine (manuale): riuscito, 93 campioni, 2 eliminati, 2 POST, 105890 byte, 10.1 s"
   ]}}
```

- Riconoscibile dalla chiave `diagnostica` (non contiene sezioni di dati).
- `righe`: al massimo **300**, solo quelle non ancora consegnate, in ordine cronologico.
  Formato: `<ISO 8601 con millisecondi> [INFO|WARN|ERRORE] [categoria] messaggio`.
  Categorie: `app`, `sync`, `tipo`, `rete`, `permessi`, `osservatore`, `background`, `diagnostica`.
- **Mai valori di salute**: solo tipi, conteggi, byte, esiti, durate ed errori
  (dominio, codice, descrizione).
- Inviato dopo ogni sincronizzazione (riuscita o no) ma **al massimo ogni 15 minuti**, e a mano
  da Impostazioni › Diagnostica. Un singolo tentativo, mai bloccante per i dati: se fallisce,
  le righe restano in coda per il giro successivo.
- Rispondi 2xx per confermare: le righe consegnate non verranno rispedite.

## Documento

```jsonc
{
  "app": "salute-libera",
  "versione": 1,
  "dispositivo": "iPhone17,1",                     // identificativo modello
  "inviato": "2026-10-01T09:41:00+02:00",          // ISO 8601 con fuso locale
  "campioni":       [ ... ],   // campioni quantitativi
  "categorie":      [ ... ],   // campioni di categoria (sonno, eventi, sintomi…)
  "allenamenti":    [ ... ],
  "ecg":            [ ... ],   // riepilogo + tracciato completo (µV); sempre in POST a parte
  "audiogrammi":    [ ... ],
  "stati_d_animo":  [ ... ],
  "eliminati":      ["uuid", ...],              // campioni cancellati in Salute
  "caratteristiche": { ... }                    // inviate una volta sola
}
```

**Sono presenti solo le sezioni che contengono dati.** Ogni POST contiene al massimo
**5000 elementi** (record + uuid eliminati, sommati su tutte le sezioni); il primo invio
(storico completo) arriva quindi in molti POST successivi.

**Gli ECG viaggiano in POST dedicati**, con al massimo **5 ECG per POST** (ognuno porta circa
15 000 valori, ~80 KB di JSON). Un POST con `ecg` contiene solo `ecg` ed eventualmente
`eliminati` (uuid di ECG cancellati); non contiene mai `campioni`, `categorie` o altre sezioni. Tutte le date sono stringhe ISO 8601
con il fuso orario del telefono, precisione al secondo.

### `campioni`

```json
{
  "uuid": "6F0D1E7A-…",
  "tipo": "HKQuantityTypeIdentifierStepCount",
  "valore": 123.0,
  "unita": "count",
  "inizio": "2026-10-01T08:00:00+02:00",
  "fine": "2026-10-01T09:00:00+02:00",
  "fonte": "iPhone di Mario",
  "metadati": {"HKWasUserEntered": "1"}          // facoltativo, sempre stringhe
}
```

`tipo` è l'identificatore HealthKit originale. `unita` è sempre quella della tabella più sotto,
fissa per tipo (non dipende dalle preferenze dell'utente).

### `categorie`

```json
{
  "uuid": "…", "tipo": "HKCategoryTypeIdentifierSleepAnalysis",
  "valore": 3, "etichetta": "asleepCore",
  "inizio": "…", "fine": "…", "fonte": "Apple Watch di Mario", "metadati": {…}
}
```

`valore` è il valore grezzo HealthKit; `etichetta` è il nome leggibile quando noto:

| Tipo | Valori |
|---|---|
| SleepAnalysis | 0 inBed, 1 asleepUnspecified, 2 awake, 3 asleepCore, 4 asleepDeep, 5 asleepREM |
| AppleStandHour | 0 stood, 1 idle |
| MenstrualFlow, Bleeding… | 1 unspecified, 2 light, 3 medium, 4 heavy, 5 none |
| Sintomi (Headache, Fatigue, …) | 0 unspecified, 1 notPresent, 2 mild, 3 moderate, 4 severe |
| MoodChanges, SleepChanges | 0 present, 1 notPresent |
| AppetiteChanges | 0 unspecified, 1 noChange, 2 decreased, 3 increased |
| CervicalMucusQuality | 1 dry, 2 sticky, 3 creamy, 4 watery, 5 eggWhite |
| OvulationTestResult | 1 negative, 2 luteinizingHormoneSurge, 3 indeterminate, 4 estrogenSurge |
| Pregnancy/ProgesteroneTestResult | 1 negative, 2 positive, 3 indeterminate |
| Contraceptive | 1 unspecified, 2 implant, 3 injection, 4 intrauterineDevice, 5 intravaginalRing, 6 oral, 7 patch |
| AppleWalkingSteadinessEvent | 1 initialLow, 2 initialVeryLow, 3 repeatLow, 4 repeatVeryLow |
| Eventi (MindfulSession, HighHeartRateEvent, …) | 0 notApplicable |

### `allenamenti`

```json
{
  "uuid": "…", "attivita": "running",
  "inizio": "…", "fine": "…", "durata_s": 2710.0,
  "energia_kcal": 412.5, "distanza_m": 7840.0,
  "fonte": "Apple Watch di Mario",
  "statistiche": {
    "HKQuantityTypeIdentifierHeartRate": {"unita": "count/min", "media": 148, "minimo": 96, "massimo": 171},
    "HKQuantityTypeIdentifierActiveEnergyBurned": {"unita": "kcal", "somma": 412.5}
  },
  "metadati": {"HKIndoorWorkout": "0"},
  "percorso": [{"lat": 45.46, "lon": 9.19, "alt": 122.0, "t": "…"}]   // solo se attivato
}
```

`attivita` è il nome inglese in snake_case di `HKWorkoutActivityType` (`running`, `cycling`,
`traditional_strength_training`, `yoga`, …; valori sconosciuti: `activity_<n>`).
`percorso` è presente solo se l'utente ha attivato «Percorsi GPS degli allenamenti» (spento di serie).

### `ecg`

```json
{"uuid": "2473D549-…", "inizio": "2026-09-30T16:23:42+02:00", "fine": "2026-09-30T16:24:12+02:00",
 "classificazione": "sinusRhythm", "bpm_medio": 64.0, "sintomi": "none",
 "fonte": "Apple Watch di Mario",
 "frequenza_hz": 512.0, "unita_tracciato": "µV",
 "tracciato": [3.6, 6.6, 4.9, 2.4, 2.3, 3.7, 2.8, -2.1, …]}
```

| Campo | Significato |
|---|---|
| `classificazione` | notSet, sinusRhythm, atrialFibrillation, inconclusiveLowHeartRate, inconclusiveHighHeartRate, inconclusivePoorReading, inconclusiveOther, unrecognized |
| `bpm_medio` | frequenza media calcolata da Apple (count/min) |
| `sintomi` | notSet, none, present |
| `frequenza_hz` | frequenza di campionamento (`samplingFrequency`), di solito 512 |
| `unita_tracciato` | sempre `"µV"` (microvolt) |
| `tracciato` | tutte le misure della derivazione `appleWatchSimilarToLeadI` (simile a DI), in ordine, arrotondate a 1 decimale. Il tempo del campione *i* è `inizio + i / frequenza_hz`. Una registrazione di 30 s a 512 Hz ≈ 15 360 valori |

`frequenza_hz`, `unita_tracciato` e `tracciato` mancano solo se Salute non fornisce misure
per quell'ECG.

**Reinvio una tantum (formato ECG v2).** Le versioni precedenti inviavano gli ECG senza
tracciato. Al primo avvio della versione con tracciato l'app azzera **solo** il segnalibro
degli ECG (valore salvato `versione_ecg` < 2 → 2) e reinvia **tutti** gli ECG una volta,
completi. Il server riceverà quindi di nuovo uuid già noti: deve aggiornarli (upsert per
`uuid`), non rifiutarli.

### `audiogrammi`

```json
{"uuid": "…", "inizio": "…", "fine": "…", "fonte": "…",
 "punti": [{"frequenza_hz": 1000, "sinistro_dbhl": 10, "destro_dbhl": 15}]}
```

### `stati_d_animo`

```json
{"uuid": "…", "inizio": "…", "tipo": "dailyMood", "valenza": 0.4,
 "classificazione": "slightlyPleasant", "etichette": ["calm", "grateful"],
 "associazioni": ["family"], "fonte": "…"}
```

### `eliminati`

Array di uuid di campioni cancellati in Salute dopo essere stati inviati (di qualsiasi sezione).
Il server dovrebbe eliminarli o marcarli come cancellati.

### `caratteristiche`

Inviate una sola volta (e di nuovo dopo «Invia di nuovo tutto lo storico»), se il gruppo
«Corpo» è attivo e almeno un valore è disponibile:

```json
{"data_di_nascita": "1984-03-12", "sesso": "male", "gruppo_sanguigno": "0+",
 "fototipo": "III", "sedia_a_rotelle": false, "modalita_movimento": "activeEnergy"}
```

`sesso`: female, male, other. `gruppo_sanguigno`: A+, A-, B+, B-, AB+, AB-, 0+, 0-.

## Unità per tipo (`campioni.unita`)

Le unità sono le canoniche di HealthKit (stringa `HKUnit.unitString`), con due scelte più
pratiche: frequenze in **count/min** invece di count/s.

> **Attenzione alle percentuali:** con l'unità `%` HealthKit esprime le frazioni:
> `OxygenSaturation` 97 % arriva come `0.97`, `BodyFatPercentage` 18 % come `0.18`.

| Unità | Tipi (prefisso `HKQuantityTypeIdentifier` omesso) |
|---|---|
| `%` | WalkingDoubleSupportPercentage, WalkingAsymmetryPercentage, AppleWalkingSteadiness, AtrialFibrillationBurden, PeripheralPerfusionIndex, OxygenSaturation, BodyFatPercentage, BloodAlcoholContent |
| `IU` | InsulinDelivery |
| `L` | ForcedVitalCapacity, ForcedExpiratoryVolume1 |
| `L/min` | PeakExpiratoryFlowRate |
| `S` | ElectrodermalActivity |
| `W` | RunningPower, CyclingPower, CyclingFunctionalThresholdPower |
| `appleEffortScore` | WorkoutEffortScore, EstimatedWorkoutEffortScore |
| `cm` | RunningVerticalOscillation |
| `count` | StepCount, PushCount, SwimmingStrokeCount, FlightsClimbed, AppleSleepingBreathingDisturbances, InhalerUsage, BodyMassIndex, NumberOfAlcoholicBeverages, NumberOfTimesFallen, UVExposure |
| `count/min` | CyclingCadence, HeartRate, RestingHeartRate, WalkingHeartRateAverage, HeartRateRecoveryOneMinute, RespiratoryRate |
| `dBASPL` | EnvironmentalAudioExposure, HeadphoneAudioExposure, EnvironmentalSoundReduction |
| `degC` | AppleSleepingWristTemperature, BodyTemperature, BasalBodyTemperature, WaterTemperature |
| `g` | DietaryCarbohydrates, DietaryProtein, DietaryFatTotal, DietaryFatSaturated, DietaryFatMonounsaturated, DietaryFatPolyunsaturated, DietaryCholesterol, DietaryFiber, DietarySugar, DietarySodium, DietaryCaffeine, DietaryCalcium, DietaryChloride, DietaryChromium, DietaryCopper, DietaryFolate, DietaryIodine, DietaryIron, DietaryMagnesium, DietaryManganese, DietaryMolybdenum, DietaryNiacin, DietaryPantothenicAcid, DietaryPhosphorus, DietaryPotassium, DietaryRiboflavin, DietarySelenium, DietaryThiamin, DietaryBiotin, DietaryVitaminA, DietaryVitaminB6, DietaryVitaminB12, DietaryVitaminC, DietaryVitaminD, DietaryVitaminE, DietaryVitaminK, DietaryZinc |
| `kcal` | ActiveEnergyBurned, BasalEnergyBurned, DietaryEnergyConsumed |
| `kcal/hr·kg` | PhysicalEffort |
| `kg` | BodyMass, LeanBodyMass |
| `m` | DistanceWalkingRunning, DistanceCycling, DistanceWheelchair, DistanceSwimming, DistanceDownhillSnowSports, DistanceCrossCountrySkiing, DistancePaddleSports, DistanceRowing, DistanceSkatingSports, RunningStrideLength, WalkingStepLength, SixMinuteWalkTestDistance, UnderwaterDepth, Height, WaistCircumference |
| `m/s` | RunningSpeed, CyclingSpeed, CrossCountrySkiingSpeed, PaddleSportsSpeed, RowingSpeed, WalkingSpeed, StairAscentSpeed, StairDescentSpeed |
| `mL` | DietaryWater |
| `mL/min·kg` | VO2Max |
| `mg/dL` | BloodGlucose |
| `min` | AppleExerciseTime, AppleMoveTime, AppleStandTime, TimeInDaylight |
| `mmHg` | BloodPressureSystolic, BloodPressureDiastolic |
| `ms` | RunningGroundContactTime, HeartRateVariabilitySDNN |

Note: `count` per BodyMassIndex e UVExposure è adimensionale; `S` è siemens;
`appleEffortScore` è la scala 1–10 di Apple; i nutrienti (Dietary…) sono tutti in grammi
eccetto energia (kcal) e acqua (mL).

## Comportamento dell'app

- **Incrementale**: per ogni tipo l'app tiene un'ancora (`HKQueryAnchor`) e chiede a Salute solo
  le novità da quel punto, incluse le cancellazioni.
- **Ripresa**: il primo invio (tutto lo storico) è spezzato in blocchi; se si interrompe riparte
  dall'ultimo blocco confermato.
- **Quando**: alla comparsa di nuovi dati (consegna in background di HealthKit: immediata per
  sonno, allenamenti, ECG ed eventi cardiaci, oraria per il resto), periodicamente con
  BGAppRefreshTask/BGProcessingTask, con «Sincronizza ora» o trascinando la schermata Oggi.
- **Blocco schermo**: con l'iPhone bloccato Salute non è leggibile; l'invio viene ritentato dopo.
