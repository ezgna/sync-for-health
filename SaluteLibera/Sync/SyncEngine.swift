import Foundation
import HealthKit
import Observation
import UIKit

/// Un solo HKHealthStore per tutta l'app.
enum Health {
    static let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Chiede l'autorizzazione in lettura per i tipi dei gruppi scelti. Salute mostra il foglio
    /// solo per i tipi mai proposti prima: aggiungere un gruppo chiede soltanto i tipi nuovi.
    static func requestAuthorization(groups: Set<DataGroup>, includeRoutes: Bool) async throws {
        guard isAvailable else { return }
        let types = HealthCatalog.readTypes(groups: groups, includeRoutes: includeRoutes)
        guard !types.isEmpty else { return }
        DiagLog.info("permessi", "richiesta autorizzazione in lettura per \(types.count) tipi, gruppi: \(groups.map(\.rawValue).sorted().joined(separator: ",")) (percorsi: \(includeRoutes ? "sì" : "no"))")
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            DiagLog.info("permessi", "foglio dei permessi chiuso")
        } catch {
            DiagLog.error("permessi", "richiesta non riuscita: \(DiagLog.describe(error))")
            throw error
        }
        await logAuthorizationStatus(groups: groups)
    }

    /// Scrive nel registro se Salute mostrerebbe ancora il foglio dei permessi.
    /// (HealthKit non rivela quali tipi in lettura sono stati concessi.)
    static func logAuthorizationStatus(groups: Set<DataGroup>) async {
        guard isAvailable else {
            DiagLog.warning("permessi", "HealthKit non disponibile su questo dispositivo")
            return
        }
        let types = HealthCatalog.readTypes(groups: groups, includeRoutes: false)
        guard !types.isEmpty else {
            DiagLog.info("permessi", "nessun gruppo scelto")
            return
        }
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: [], read: types)
            let text = switch status {
            case .shouldRequest: "da chiedere (ci sono tipi mai proposti)"
            case .unnecessary: "già chiesta per tutti i tipi"
            case .unknown: "sconosciuto"
            @unknown default: "valore \(status.rawValue)"
            }
            DiagLog.info("permessi", "stato richiesta autorizzazione: \(text)")
        } catch {
            DiagLog.error("permessi", "stato autorizzazione non leggibile: \(DiagLog.describe(error))")
        }
    }
}

/// Stato della sincronizzazione mostrato nell'interfaccia.
@MainActor
@Observable
final class SyncCenter {
    static let shared = SyncCenter()

    enum Phase: Equatable {
        case idle
        case syncing
        case success
        /// Alcuni blocchi consegnati, poi fermo: riprende da solo.
        case paused(String)
        /// iPhone bloccato: Salute non è leggibile. Stato neutro, non un errore.
        case waitingUnlock
        case failure(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = SyncProgress()
    private(set) var lastCheck: Date?
    private(set) var trigger: SyncRecord.Trigger?
    /// L'iPhone è tenuto sveglio (isIdleTimerDisabled) durante un invio grande in primo piano.
    private(set) var keepingAwake = false
    /// Incrementati a ogni esito: usati per l'aptica.
    private(set) var successTick = 0
    private(set) var failureTick = 0

    private init() {
        lastCheck = UserDefaults.standard.object(forKey: "ultimoControllo") as? Date
        if let last = SyncLog.shared.records.first { phase = Self.phase(for: last) ?? .idle }
    }

    var isSyncing: Bool { phase == .syncing }

    /// Lo storico completo non è ancora arrivato tutto al server.
    var historyPending: Bool {
        !UserDefaults.standard.bool(forKey: AppSettings.Keys.historyComplete)
    }

    func syncNow(_ trigger: SyncRecord.Trigger = .manuale) {
        Task { await SyncCoordinator.shared.request(trigger) }
    }

    func began(_ trigger: SyncRecord.Trigger) {
        self.trigger = trigger
        progress = SyncProgress()
        phase = .syncing
        refreshKeepAwake()
    }

    func progressed(_ p: SyncProgress) { progress = p }

    /// Un invio a mano o lo storico completo, in primo piano: lo schermo non si spegne.
    func refreshKeepAwake() {
        let big = trigger == .manuale || trigger == .storico || historyPending
        let active = UIApplication.shared.applicationState == .active
        setKeepAwake(isSyncing && big && active)
    }

    func setKeepAwake(_ on: Bool) {
        guard on != keepingAwake else { return }
        keepingAwake = on
        UIApplication.shared.isIdleTimerDisabled = on
        DiagLog.info("app", on ? "schermo tenuto acceso durante l'invio" : "blocco automatico dello schermo ripristinato")
    }

    func finished(_ record: SyncRecord?) {
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: "ultimoControllo")
        defer { setKeepAwake(false) }
        guard let record else {
            if phase == .syncing { phase = .success }
            return
        }
        phase = Self.phase(for: record) ?? .idle
        switch record.outcome {
        case .riuscito, .nienteDaInviare: successTick += 1
        case .errore: failureTick += 1
        default: break
        }
    }

    private static func phase(for record: SyncRecord) -> Phase? {
        switch record.outcome {
        case .riuscito, .nienteDaInviare: .success
        case .parziale: .paused(record.message ?? "")
        case .inAttesa: .waitingUnlock
        case .errore: .failure(record.message ?? "")
        case .interrotto: record.samples > 0 ? .paused(record.message ?? "") : nil
        }
    }
}

/// Serializza le sincronizzazioni: una alla volta; le richieste arrivate durante
/// un invio provocano un nuovo giro subito dopo.
actor SyncCoordinator {
    static let shared = SyncCoordinator()

    private var running: Task<Void, Never>?
    private var rerun = false
    private var pendingTrigger: SyncRecord.Trigger = .automatico

    func request(_ trigger: SyncRecord.Trigger) async {
        if let running {
            rerun = true
            if trigger == .manuale || trigger == .storico { pendingTrigger = trigger }
            await running.value
            return
        }
        let task = Task { await self.loop(first: trigger) }
        running = task
        await task.value
    }

    /// Interrompe l'invio in corso (scadenza di un task in background).
    func cancel() {
        if running != nil { DiagLog.warning("sync", "invio in corso annullato") }
        running?.cancel()
    }

    private func loop(first: SyncRecord.Trigger) async {
        var trigger = first
        repeat {
            rerun = false
            await runOnce(trigger)
            trigger = pendingTrigger
            pendingTrigger = .automatico
        } while rerun && !Task.isCancelled
        running = nil
    }

    private func runOnce(_ trigger: SyncRecord.Trigger) async {
        let settings = await MainActor.run { AppSettings.shared.snapshot }
        // Le sincronizzazioni automatiche tacciono finché non c'è un indirizzo.
        if settings.endpoint == nil, trigger != .manuale, trigger != .storico, !AppEnvironment.isDemo {
            DiagLog.info("sync", "\(trigger.rawValue): nessun indirizzo configurato, salto")
            return
        }
        let quietTrigger = trigger == .automatico || trigger == .background
        // Con l'iPhone bloccato Salute non è leggibile: non è un errore, si aspetta lo sblocco.
        let unlocked = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        let skipLockCheck = AppEnvironment.isDemo
        if !unlocked, !skipLockCheck {
            DiagLog.info("sync", "\(trigger.rawValue): dati protetti non disponibili (iPhone bloccato), in attesa dello sblocco")
            let record = SyncRecord(date: Date(), samples: 0, deleted: 0, outcome: .inAttesa, trigger: trigger,
                                    message: String(localized: "In attesa dello sblocco dell'iPhone"),
                                    duration: 0, bytes: 0, requests: 0)
            await MainActor.run {
                if !quietTrigger { SyncLog.shared.add(record) }
                SyncCenter.shared.finished(record)
            }
            return
        }

        DiagLog.info("sync", "inizio (\(trigger.rawValue)), gruppi: \(settings.groups.map(\.rawValue).sorted().joined(separator: ",")), gzip: \(settings.gzip ? "sì" : "no")")
        await MainActor.run { SyncCenter.shared.began(trigger) }
        let job = SyncJob(settings: settings, trigger: trigger)
        let record = await job.run { p in
            await MainActor.run { SyncCenter.shared.progressed(p) }
        }
        let line = "fine (\(trigger.rawValue)): \(record.outcome.rawValue), \(record.samples) campioni, \(record.deleted) eliminati, \(record.requests) POST, \(record.bytes) byte, \(String(format: "%.1f", record.duration)) s"
        if record.outcome == .errore {
            DiagLog.error("sync", line + " — \(record.message ?? "")")
        } else {
            DiagLog.info("sync", line + (record.message.map { " — \($0)" } ?? ""))
        }
        if record.outcome == .riuscito || record.outcome == .nienteDaInviare {
            UserDefaults.standard.set(true, forKey: AppSettings.Keys.historyComplete)
        }
        await MainActor.run {
            // In automatico non si registrano "niente da inviare" e "in attesa", per non affollare il registro.
            let quiet = quietTrigger && (record.outcome == .nienteDaInviare
                                         || (record.outcome == .inAttesa && record.samples == 0))
            if !quiet { SyncLog.shared.add(record) }
            SyncCenter.shared.finished(record)
        }
        if record.outcome == .riuscito || record.outcome == .nienteDaInviare {
            BackgroundTasks.scheduleAll()
        }
        // Diagnostica al server: mai bloccante per i dati, al massimo ogni 15 minuti.
        Task.detached(priority: .utility) { await DiagShipper.shared.shipIfDue() }
    }
}

/// Un giro di sincronizzazione: query ancorate per tipo, invii a blocchi,
/// ancore salvate solo dopo una risposta 2xx.
struct SyncJob: Sendable {
    let settings: SettingsSnapshot
    let trigger: SyncRecord.Trigger

    /// Massimo numero di elementi (campioni + eliminati) per POST.
    static let maxPerPost = 5000

    typealias Progress = @Sendable (SyncProgress) async -> Void

    func run(progress: @escaping Progress) async -> SyncRecord {
        let start = Date()
        var record = SyncRecord(date: start, samples: 0, deleted: 0, outcome: .nienteDaInviare,
                                trigger: trigger, message: nil, duration: 0, bytes: 0, requests: 0)
        // Modalità dimostrativa: dati sintetici. Se c'è un indirizzo vengono spediti davvero
        // (per provare il server), altrimenti l'invio è solo simulato. Salute non viene letta.
        if AppEnvironment.isDemo {
            let uploader = settings.endpoint.map { Uploader(endpoint: $0, token: settings.token, gzip: settings.gzip) }
            return await DemoData.runDemoSync(uploader: uploader, record: record, progress: progress)
        }
        guard let endpoint = settings.endpoint else {
            record.outcome = .errore
            record.message = String(localized: "Configura l'indirizzo di destinazione nelle Impostazioni.")
            return record
        }
        let uploader = Uploader(endpoint: endpoint, token: settings.token, gzip: settings.gzip)

        guard Health.isAvailable else {
            record.outcome = .errore
            record.message = String(localized: "Salute non è disponibile su questo dispositivo.")
            return record
        }

        Self.migrateIfNeeded()
        var batch = Batch()
        let defaults = UserDefaults.standard
        if settings.groups.contains(.corpo), !defaults.bool(forKey: AppSettings.Keys.characteristicsSent) {
            let c = Serializer.characteristics(store: Health.store)
            if !c.isEmpty { batch.characteristics = c }
        }

        let entries = HealthCatalog.entries(in: settings.groups)
        var status = SyncProgress(typeCount: entries.count)
        var quietTypes = 0
        do {
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                guard let type = entry.sampleType else { continue }
                status.typeIndex = index + 1
                status.typeIdentifier = entry.id
                await progress(status)
                let hadAnchor = AnchorStore.shared.anchor(for: entry.id) != nil
                var read = 0, removed = 0, pages = 0
                if entry.kind == .electrocardiogram {
                    // Gli ECG col tracciato sono grandi: POST dedicati, al massimo 5 per volta.
                    (read, removed, pages) = try await syncElectrocardiograms(
                        entry, type: type, uploader: uploader, record: &record, status: &status, progress: progress)
                } else {
                    var anchor = AnchorStore.shared.anchor(for: entry.id)
                    let pageLimit = Self.pageLimit(entry, routes: settings.includeRoutes)
                    while true {
                        let room = Self.maxPerPost - batch.count
                        let limit = max(min(pageLimit, room), min(pageLimit, 100))
                        let query = HKAnchoredObjectQueryDescriptor(
                            predicates: [.sample(type: type)], anchor: anchor, limit: limit)
                        let result = try await query.result(for: Health.store)
                        pages += 1
                        read += result.addedSamples.count
                        removed += result.deletedObjects.count
                        try await batch.add(result.addedSamples, entry: entry, includeRoutes: settings.includeRoutes)
                        batch.deleted += result.deletedObjects.map(\.uuid.uuidString)
                        if let data = AnchorStore.archive(result.newAnchor) { batch.anchors[entry.id] = data }
                        anchor = result.newAnchor
                        if batch.count >= Self.maxPerPost {
                            try await flush(&batch, uploader: uploader, record: &record)
                            status.samplesSent = record.samples + record.deleted
                            status.blocksSent = record.requests
                            await progress(status)
                        }
                        if result.addedSamples.count + result.deletedObjects.count < limit { break }
                    }
                }
                if read + removed > 0 || !hadAnchor {
                    DiagLog.info("tipo", "\(entry.id): ancora \(hadAnchor ? "presente" : "assente"), letti \(read), eliminati \(removed), pagine \(pages)")
                } else {
                    quietTypes += 1
                }
            }
            try await flush(&batch, uploader: uploader, record: &record)
            status.samplesSent = record.samples + record.deleted
            status.blocksSent = record.requests
            await progress(status)
            DiagLog.info("tipo", "\(quietTypes) tipi senza novità")
            record.outcome = record.samples + record.deleted > 0 || record.requests > 0 ? .riuscito : .nienteDaInviare
        } catch {
            DiagLog.error("sync", "interrotto al tipo \(status.typeIndex)/\(status.typeCount) \(status.typeIdentifier ?? "?"): \(DiagLog.describe(error))")
            classify(error, into: &record)
        }
        record.duration = Date().timeIntervalSince(start)
        return record
    }

    /// Decide l'esito di un invio che si è fermato per un errore.
    /// Se alcuni blocchi sono già arrivati al server, l'invio è «parziale» (non un errore).
    private func classify(_ error: Error, into record: inout SyncRecord) {
        let delivered = record.samples + record.deleted > 0
        if let hk = error as? HKError, hk.code == .errorDatabaseInaccessible {
            record.outcome = delivered ? .parziale : .inAttesa
            record.message = delivered
                ? String(localized: "In pausa: iPhone bloccato, riprende da solo")
                : String(localized: "In attesa dello sblocco dell'iPhone")
            return
        }
        let cancelled: Bool = {
            if error is CancellationError { return true }
            if let up = error as? UploadError, case .cancelled = up { return true }
            return false
        }()
        if cancelled {
            record.outcome = delivered ? .parziale : .interrotto
            record.message = String(localized: "Invio interrotto: riprenderà dal punto in cui si è fermato.")
            return
        }
        let message = (error as? UploadError)?.localizedDescription ?? error.localizedDescription
        record.outcome = delivered ? .parziale : .errore
        record.message = delivered
            ? String(localized: "In pausa: \(message) Riprenderà da qui.")
            : message
    }

    /// Massimo numero di ECG (con tracciato, ~100 KB l'uno) per POST.
    static let maxECGPerPost = 5

    /// Versione del formato ECG: 2 = con tracciato. Se quella salvata è minore, l'ancora
    /// degli ECG viene azzerata una sola volta, così tutti gli ECG ripartono col tracciato.
    static let ecgFormatVersion = 2
    static let ecgFormatKey = "versione_ecg"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: ecgFormatKey) < ecgFormatVersion else { return }
        AnchorStore.shared.remove("HKDataTypeIdentifierElectrocardiogram")
        defaults.set(ecgFormatVersion, forKey: ecgFormatKey)
        DiagLog.info("sync", "migrazione ECG v\(ecgFormatVersion): segnalibro ECG azzerato, tutti gli ECG verranno reinviati col tracciato")
    }

    /// ECG in POST separati: ogni pagina (≤ 5 ECG) viene letta per intero, inviata, e solo
    /// dopo il 2xx se ne salva l'ancora. Un tracciato alla volta in memoria durante la lettura.
    private func syncElectrocardiograms(_ entry: CatalogEntry, type: HKSampleType, uploader: Uploader,
                                        record: inout SyncRecord, status: inout SyncProgress,
                                        progress: @escaping Progress) async throws -> (Int, Int, Int) {
        var anchor = AnchorStore.shared.anchor(for: entry.id)
        var read = 0, removed = 0, pages = 0
        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(
                predicates: [.sample(type: type)], anchor: anchor, limit: Self.maxECGPerPost)
            let result = try await query.result(for: Health.store)
            var page = Batch()
            try await page.add(result.addedSamples, entry: entry, includeRoutes: false)
            page.deleted = result.deletedObjects.map(\.uuid.uuidString)
            if let data = AnchorStore.archive(result.newAnchor) { page.anchors[entry.id] = data }
            anchor = result.newAnchor
            pages += 1
            read += result.addedSamples.count
            removed += result.deletedObjects.count
            try await flush(&page, uploader: uploader, record: &record)
            status.samplesSent = record.samples + record.deleted
            status.blocksSent = record.requests
            await progress(status)
            if result.addedSamples.count + result.deletedObjects.count < Self.maxECGPerPost { break }
        }
        return (read, removed, pages)
    }

    /// Invia il blocco corrente; solo dopo il 2xx salva le ancore.
    private func flush(_ batch: inout Batch, uploader: Uploader, record: inout SyncRecord) async throws {
        if batch.isEmptyPayload {
            // Nulla da inviare ma ancore aggiornate (es. tipi senza dati): si salvano subito.
            AnchorStore.shared.commit(batch.anchors)
            batch.anchors = [:]
            return
        }
        let payload = batch.makePayload()
        let bytes = try await uploader.send(payload)
        AnchorStore.shared.commit(batch.anchors)
        if payload.caratteristiche != nil {
            UserDefaults.standard.set(true, forKey: AppSettings.Keys.characteristicsSent)
        }
        record.samples += batch.recordCount
        record.deleted += batch.deleted.count
        record.bytes += bytes
        record.requests += 1
        batch = Batch()
    }

    static func pageLimit(_ entry: CatalogEntry, routes: Bool) -> Int {
        switch entry.kind {
        case .workout: routes ? 20 : 200
        case .electrocardiogram: maxECGPerPost
        case .audiogram: 200
        default: maxPerPost
        }
    }
}

/// Accumulatore di record per un singolo POST.
struct Batch {
    var quantities: [QuantityRecord] = []
    var categories: [CategoryRecord] = []
    var workouts: [WorkoutRecord] = []
    var ecgs: [ECGRecord] = []
    var audiograms: [AudiogramRecord] = []
    var moods: [StateOfMindRecord] = []
    var deleted: [String] = []
    var characteristics: Characteristics?
    var anchors: [String: Data] = [:]

    var recordCount: Int {
        quantities.count + categories.count + workouts.count + ecgs.count + audiograms.count + moods.count
    }

    var count: Int { recordCount + deleted.count }

    var isEmptyPayload: Bool { count == 0 && characteristics == nil }

    mutating func add(_ samples: [HKSample], entry: CatalogEntry, includeRoutes: Bool) async throws {
        switch entry.kind {
        case .quantity:
            guard let unit = entry.unit else { return }
            for case let s as HKQuantitySample in samples { quantities.append(Serializer.quantity(s, unit: unit)) }
        case .category:
            for case let s as HKCategorySample in samples { categories.append(Serializer.category(s)) }
        case .workout:
            for case let w as HKWorkout in samples {
                workouts.append(await Serializer.workout(w, store: Health.store, includeRoute: includeRoutes))
            }
        case .electrocardiogram:
            // Un ECG alla volta: il tracciato viene letto tutto prima di passare al successivo.
            for case let e as HKElectrocardiogram in samples {
                ecgs.append(try await Serializer.electrocardiogram(e, store: Health.store))
            }
        case .audiogram:
            for case let a as HKAudiogramSample in samples { audiograms.append(Serializer.audiogram(a)) }
        case .stateOfMind:
            for case let m as HKStateOfMind in samples { moods.append(Serializer.stateOfMind(m)) }
        }
    }

    func makePayload() -> Payload {
        Payload(
            dispositivo: Uploader.deviceModel,
            inviato: ISO.string(Date()),
            campioni: quantities.isEmpty ? nil : quantities,
            categorie: categories.isEmpty ? nil : categories,
            allenamenti: workouts.isEmpty ? nil : workouts,
            ecg: ecgs.isEmpty ? nil : ecgs,
            audiogrammi: audiograms.isEmpty ? nil : audiograms,
            stati_d_animo: moods.isEmpty ? nil : moods,
            eliminati: deleted.isEmpty ? nil : deleted,
            caratteristiche: characteristics)
    }
}

/// Prova di connessione: POST di {"app":"salute-libera","versione":1,"prova":true}.
enum ConnectionTest {
    static func run(endpoint: String, token: String, gzip: Bool) async -> Result<Int, UploadError> {
        guard let url = AppSettings.validURL(endpoint) else {
            return .failure(.network(String(localized: "Indirizzo non valido: usa https:// (http solo in rete locale).")))
        }
        let uploader = Uploader(endpoint: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), gzip: gzip)
        do {
            let bytes = try await uploader.send(TestPayload(), attempts: 1)
            return .success(bytes)
        } catch let e as UploadError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
