import Foundation

/// Dati di esempio, interamente sintetici, per la modalità dimostrativa
/// (interruttore in Impostazioni, oppure `-demo` nelle build DEBUG).
/// Rendono provabile l'app senza dati in Salute e senza server. La dimostrazione
/// è esclusivamente locale: non costruisce né trasmette payload sanitari.
enum DemoData {
    static func today() -> TodaySnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

        var s = TodaySnapshot()
        let steps: [Double] = [7120, 9840, 6310, 8950, 10420, 7780, 8210, 8432]
        s.stepsWeek = steps.enumerated().map { DayValue(date: day($0.offset - 7), value: $0.element) }
        s.steps = steps.last
        s.activeEnergy = 486
        s.energyGoal = 600
        s.exerciseMinutes = 34
        s.standHours = 9
        s.standGoal = 12
        s.restingHR = 57
        s.restingSeries = [61, 60, 59, 60, 58, 58, 57].enumerated()
            .map { DayValue(date: day($0.offset - 6), value: $0.element) }
        s.hrv = 48
        s.hrvSeries = [41, 44, 39, 47, 45, 51, 48].enumerated()
            .map { DayValue(date: day($0.offset - 6), value: $0.element) }
        s.respiratoryRate = 14.2
        s.oxygen = 97

        // Notte: 23:38 → 07:04 con cicli realistici.
        var t = cal.date(byAdding: .minute, value: -22, to: today)!
        let plan: [(SleepStage, Int)] = [
            (.awake, 6), (.core, 34), (.deep, 48), (.core, 26), (.rem, 18), (.core, 40), (.deep, 32),
            (.core, 22), (.awake, 4), (.rem, 28), (.core, 46), (.deep, 14), (.core, 30), (.rem, 34),
            (.awake, 3), (.core, 38), (.rem, 22), (.awake, 1),
        ]
        var segments: [SleepSegment] = []
        for (stage, minutes) in plan {
            let end = t.addingTimeInterval(TimeInterval(minutes * 60))
            segments.append(SleepSegment(stage: stage, start: t, end: end))
            t = end
        }
        s.sleep = SleepNight(segments: segments)

        let wave = syntheticECG()
        let w = ECGSummary.window(from: wave, hz: 512)
        s.ecg = ECGSummary(date: Date().addingTimeInterval(-26 * 3600), classification: "sinusRhythm",
                           averageBPM: 64, window: w.values, windowHz: w.hz)
        return s
    }

    /// Tracciato sintetico realistico (onde P, QRS, T) in µV, con lieve variabilità del battito,
    /// deriva della linea di base e un po' di rumore. Deterministico.
    static func syntheticECG(seconds: Double = 30, hz: Double = 512, bpm: Double = 64) -> [Double] {
        let period = 60 / bpm
        var beats: [Double] = []
        var t = 0.35
        var k = 0
        while t < seconds + 1 {
            beats.append(t)
            t += period * (1 + 0.035 * sin(Double(k) * 0.9))
            k += 1
        }
        func g(_ x: Double, _ center: Double, _ width: Double, _ amp: Double) -> Double {
            let d = (x - center) / width
            return amp * exp(-0.5 * d * d)
        }
        let count = Int(seconds * hz)
        var out = [Double](repeating: 0, count: count)
        var bi = 0
        for i in 0..<count {
            let x = Double(i) / hz
            while bi + 1 < beats.count, abs(beats[bi + 1] - x) < abs(beats[bi] - x) { bi += 1 }
            var v = 0.0
            for r in beats[max(0, bi - 1)...min(beats.count - 1, bi + 1)] {
                v += g(x, r - 0.165, 0.024, 85)     // P
                v += g(x, r - 0.028, 0.009, -95)    // Q
                v += g(x, r, 0.0105, 880)           // R
                v += g(x, r + 0.030, 0.011, -230)   // S
                v += g(x, r + 0.285, 0.048, 210)    // T
            }
            v += 38 * sin(2 * .pi * 0.23 * x) + 6 * sin(2 * .pi * 47.0 * x) + 4 * sin(2 * .pi * 91.3 * x + 1.1)
            out[i] = (v * 10).rounded() / 10
        }
        return out
    }

    static func records() -> [SyncRecord] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var list: [SyncRecord] = [
            SyncRecord(date: ago(4), samples: 214, deleted: 0, outcome: .riuscito, trigger: .automatico,
                       duration: 0.8, bytes: 61_204, requests: 1),
            SyncRecord(date: ago(31), samples: 0, deleted: 0, outcome: .inAttesa, trigger: .manuale,
                       message: String(localized: "In attesa dello sblocco dell'iPhone"), duration: 0, bytes: 0, requests: 0),
            SyncRecord(date: ago(38), samples: 2_265_000, deleted: 14, outcome: .parziale, trigger: .manuale,
                       message: String(localized: "In pausa: iPhone bloccato, riprende da solo"),
                       duration: 2_712, bytes: 655_210_400, requests: 453),
            SyncRecord(date: ago(66), samples: 1_386, deleted: 2, outcome: .riuscito, trigger: .background,
                       duration: 2.4, bytes: 402_118, requests: 1),
            SyncRecord(date: ago(128), samples: 0, deleted: 0, outcome: .nienteDaInviare, trigger: .manuale,
                       duration: 0.3, bytes: 0, requests: 0),
            SyncRecord(date: ago(190), samples: 0, deleted: 0, outcome: .errore, trigger: .background,
                       message: "Il server ha un problema temporaneo (502).", duration: 31.0, bytes: 0, requests: 0),
            SyncRecord(date: ago(255), samples: 3_912, deleted: 0, outcome: .riuscito, trigger: .automatico,
                       duration: 4.1, bytes: 1_120_400, requests: 1),
        ]
        // Giorni precedenti: invii regolari, con qualche intoppo.
        let pattern: [(Int, Int)] = [(1, 6), (2, 5), (3, 7), (4, 4), (5, 6), (6, 3)]
        for (day, count) in pattern {
            for i in 0..<count {
                let minutes = Double(day * 1440) - Double(i * 170 + 40)
                let failed = (day + i) % 9 == 0
                let n = 180 + ((day * 37 + i * 211) % 1900)
                list.append(SyncRecord(
                    date: ago(minutes), samples: failed ? 0 : n, deleted: (i == 2 ? 1 : 0),
                    outcome: failed ? .errore : .riuscito,
                    trigger: i % 3 == 0 ? .background : .automatico,
                    message: failed ? "La connessione Internet sembra non essere attiva." : nil,
                    duration: failed ? 12 : Double(n) / 900, bytes: failed ? 0 : n * 290, requests: failed ? 0 : 1))
            }
        }
        list.append(SyncRecord(date: ago(60 * 24 * 6 + 30), samples: 241_380, deleted: 0, outcome: .riuscito,
                               trigger: .storico, duration: 96.4, bytes: 70_402_330, requests: 49))
        return Array(list.sorted { $0.date > $1.date }.prefix(SyncLog.limit))
    }

    /// Local-only animation. This API deliberately accepts no uploader/endpoint,
    /// and returns zero delivered samples/bytes/requests with no sync success.
    static func runDemoSync(record: SyncRecord, progress: SyncJob.Progress) async -> SyncRecord {
        var record = record
        record.samples = 0
        record.deleted = 0
        record.bytes = 0
        record.requests = 0
        record.outcome = .interrotto
        record.message = String(localized: "Dimostrazione locale: nessun dato inviato.")
        let start = Date()
        let types = ["HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate",
                     "HKCategoryTypeIdentifierSleepAnalysis", "HKWorkoutTypeIdentifier"]
        var status = SyncProgress(typeCount: types.count)
        do {
            for (index, type) in types.enumerated() {
                try Task.checkCancellation()
                status.typeIndex = index + 1
                status.typeIdentifier = type
                await progress(status)
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            record.message = String(localized: "Dimostrazione locale interrotta: nessun dato inviato.")
        }
        record.duration = Date().timeIntervalSince(start)
        return record
    }

}

/// Accende e spegne la modalità dimostrativa senza riavviare l'app.
@MainActor
enum DemoMode {
    static func apply(_ on: Bool) {
        DiagLog.info("app", on ? "modalità dimostrativa accesa" : "modalità dimostrativa spenta")
        if on {
            HealthBackground.stop()
            SyncLog.shared.replaceForDemo(DemoData.records())
        } else {
            SyncLog.shared.reloadFromDisk()
            if AppSettings.shared.onboardingDone {
                HealthBackground.start(groups: AppSettings.shared.enabledGroups)
            }
        }
        Task { await TodayModel.shared.refresh() }
    }
}
