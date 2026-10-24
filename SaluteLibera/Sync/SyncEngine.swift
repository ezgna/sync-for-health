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

    /// Demo animation must not alter the real last-check time or success state.
    func finishedDemo() {
        phase = .idle
        trigger = nil
        progress = SyncProgress()
        setKeepAwake(false)
    }

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
    private var running: Task<Bool, Never>?
    private var activeSettings: SettingsSnapshot?
    private var rerun = false
    private var pendingTrigger: SyncRecord.Trigger = .automatico

    /// Returns actual scan success, rather than just task non-cancellation.
    @discardableResult
    func request(_ trigger: SyncRecord.Trigger) async -> Bool {
        guard !Task.isCancelled else { return false }
        let desired = await MainActor.run { AppSettings.shared.snapshot }
        if let running {
            if running.isCancelled || activeSettings.map({ $0.revision != desired.revision }) == true {
                running.cancel()
                _ = await running.value
                guard !Task.isCancelled else { return false }
                return await request(trigger)
            }
            rerun = true
            if trigger == .manuale || trigger == .storico { pendingTrigger = trigger }
            return await running.value
        }
        let task = Task { await self.loop(first: trigger) }
        running = task
        return await task.value
    }

    func cancel() {
        rerun = false
        running?.cancel()
    }

    /// A delayed settings callback must never cancel a job which already uses
    /// newer settings. Check the actual active snapshot, then verify it is still
    /// the same scan after the MainActor hop. Once a revision is stale it is
    /// never reused, even if the user later restores the same visible settings.
    func cancelStale(revision _: UUID) async {
        guard let task = running, let snapshot = activeSettings else { return }
        let stale = await MainActor.run { !AppSettings.shared.isCurrent(snapshot) }
        guard stale, activeSettings?.revision == snapshot.revision else { return }
        rerun = false
        task.cancel()
        _ = await task.value
    }

    private func loop(first: SyncRecord.Trigger) async -> Bool {
        var trigger = first
        var succeeded = false
        repeat {
            rerun = false
            succeeded = await runOnce(trigger)
            trigger = pendingTrigger
            pendingTrigger = .automatico
        } while rerun && !Task.isCancelled
        activeSettings = nil
        running = nil
        return succeeded && !Task.isCancelled
    }

    private func runOnce(_ trigger: SyncRecord.Trigger) async -> Bool {
        let settings = await MainActor.run { AppSettings.shared.snapshot }
        activeSettings = settings
        guard settings.syncEnabled, !Task.isCancelled else { return false }
        if settings.endpoint == nil, trigger != .manuale, trigger != .storico, !AppEnvironment.isDemo {
            return false
        }
        let quietTrigger = trigger == .automatico || trigger == .background
        let unlocked = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        if !unlocked, !AppEnvironment.isDemo {
            let record = SyncRecord(date: Date(), samples: 0, deleted: 0, outcome: .inAttesa, trigger: trigger,
                                    message: String(localized: "In attesa dello sblocco dell'iPhone"),
                                    duration: 0, bytes: 0, requests: 0)
            await MainActor.run {
                if !quietTrigger { SyncLog.shared.add(record) }
                SyncCenter.shared.finished(record)
            }
            return false
        }
        await MainActor.run { SyncCenter.shared.began(trigger) }
        let demoRun = AppEnvironment.isDemo
        let job = SyncJob(settings: settings, trigger: trigger)
        let record = await job.run { p in
            await MainActor.run { SyncCenter.shared.progressed(p) }
        }
        if demoRun {
            await MainActor.run { SyncCenter.shared.finishedDemo() }
            return false
        }
        DiagLog.info("sync", "fine: \(record.outcome.rawValue), \(record.samples) campioni, \(record.deleted) eliminati, \(record.requests) POST")
        let succeeded = record.outcome == .riuscito || record.outcome == .nienteDaInviare
        let current = await MainActor.run {
            guard AppSettings.shared.isCurrent(settings) else { return false }
            // Keep the revision check and completion flag on the same actor as
            // namespace changes, so an old scan cannot complete a new scope.
            if succeeded { UserDefaults.standard.set(true, forKey: AppSettings.Keys.historyComplete) }
            return true
        }
        await MainActor.run {
            if !(quietTrigger && record.outcome == .nienteDaInviare) { SyncLog.shared.add(record) }
            SyncCenter.shared.finished(record)
        }
        if succeeded && current {
            BackgroundTasks.scheduleAll()
            if settings.diagnosticsEnabled {
                Task.detached(priority: .utility) { await DiagShipper.shared.shipIfDue() }
            }
        }
        return succeeded && current
    }
}

/// A scan acknowledges each bounded HTTP chunk, then persists its HealthKit page
/// cursor. Failure between chunks safely replays that page by sample UUID.
struct SyncJob: Sendable {
    let settings: SettingsSnapshot
    let trigger: SyncRecord.Trigger
    static let maxPerPost = 500
    static let maxECGPerPost = 5
    static let maxPayloadBytes = 8 * 1024 * 1024
    typealias Progress = @Sendable (SyncProgress) async -> Void
    static let pendingAuthorizationMessage = "一部のデータは読み取り権限の確認待ちです。読み取れたデータの同期は完了しました。"

    /// Do not turn device locking, cancellation, malformed data or transport
    /// errors into a successful scan. These are the actual authorization cases
    /// declared in Apple's HKDefines.h, not arbitrary NSError numeric codes.
    static func isReadAuthorizationError(_ error: Error) -> Bool {
        guard let healthError = error as? HKError else { return false }
        switch healthError.code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorRequiredAuthorizationDenied:
            return true
        default:
            return false
        }
    }

    enum Failure: LocalizedError {
        case oversizedRecord
        case invalidRecord
        var errorDescription: String? {
            switch self {
            case .oversizedRecord: "Un singolo campione supera il limite di 8 MiB. Nessun campione è stato saltato."
            case .invalidRecord: "Il campione non corrisponde al tipo HealthKit richiesto."
            }
        }
    }

    struct RouteReconciliation: Codable {
        var targetAnchor: Data
        var workoutAnchor: Data?
    }

    func ensureCurrent() async throws {
        try Task.checkCancellation()
        guard await MainActor.run(body: { AppSettings.shared.isCurrent(settings) }) else {
            throw CancellationError()
        }
    }

    func run(progress: @escaping Progress) async -> SyncRecord {
        let start = Date()
        var record = SyncRecord(date: start, samples: 0, deleted: 0, outcome: .nienteDaInviare,
                                trigger: trigger, message: nil, duration: 0, bytes: 0, requests: 0)
        guard settings.syncEnabled else { record.outcome = .interrotto; return record }
        if AppEnvironment.isDemo {
            return await DemoData.runDemoSync(record: record, progress: progress)
        }
        guard let endpoint = settings.endpoint else {
            record.outcome = .errore
            record.message = String(localized: "Configura l'indirizzo di destinazione nelle Impostazioni.")
            return record
        }
        guard Health.isAvailable else {
            record.outcome = .errore
            record.message = String(localized: "Salute non è disponibile su questo dispositivo.")
            return record
        }
        let uploader = Uploader(endpoint: endpoint, token: settings.token, gzip: settings.gzip)
        let scanID = UUID().uuidString
        let entries = HealthCatalog.entries(in: settings.groups)
        var status = SyncProgress(typeCount: entries.count)
        var pendingTypes: Set<String> = []
        do {
            try await ensureCurrent()
            // Characteristics can change, and permissions can change. An empty
            // object explicitly clears the receiver's previous snapshot.
            if settings.groups.contains(.corpo) {
                var batch = Batch()
                batch.characteristics = Serializer.characteristics(store: Health.store)
                try await send(&batch, uploader: uploader, record: &record)
            }
            if settings.includeRoutes && settings.groups.contains(.allenamenti) {
                do {
                    try await reconcileRoutes(uploader: uploader, record: &record, status: &status, progress: progress)
                } catch {
                    guard Self.isReadAuthorizationError(error) else { throw error }
                    pendingTypes.insert(HKSeriesType.workoutRoute().identifier)
                }
            }
            for (index, entry) in entries.enumerated() {
                try await ensureCurrent()
                guard let type = entry.sampleType else { continue }
                status.typeIndex = index + 1
                status.typeIdentifier = entry.id
                await progress(status)
                do {
                    var anchor = try AnchorStore.shared.anchor(for: entry.id, destination: settings.destinationID)
                    let limit = Self.pageLimit(entry, routes: settings.includeRoutes)
                    while true {
                        try await ensureCurrent()
                        let query = HKAnchoredObjectQueryDescriptor(predicates: [.sample(type: type)], anchor: anchor, limit: limit)
                        let result = try await query.result(for: Health.store)
                        let archived = try AnchorStore.archive(result.newAnchor)
                        try await sendPage(result.addedSamples, deleted: result.deletedObjects.map(\.uuid.uuidString),
                                           entry: entry, uploader: uploader, record: &record)
                        try await ensureCurrent()
                        try AnchorStore.shared.commit([entry.id: archived], destination: settings.destinationID)
                        anchor = result.newAnchor
                        status.samplesSent = record.samples + record.deleted
                        status.blocksSent = record.requests
                        await progress(status)
                        // Includes deletion-only pages and commits the final empty
                        // page, including when a preceding page exactly hit limit.
                        if result.addedSamples.count + result.deletedObjects.count < limit { break }
                    }
                } catch {
                    guard Self.isReadAuthorizationError(error) else { throw error }
                    // Do not commit the failed page or pretend that this type
                    // was empty. Continue independently authorized data types.
                    pendingTypes.insert(entry.id)
                }
            }
            pendingTypes.formUnion(try await syncSupplementalSnapshots(uploader: uploader, record: &record))
            try await ensureCurrent()
            var checkpoint = Batch().makePayload(settings: settings)
            checkpoint.checkpoint = SyncCheckpoint(scan_id: scanID, completed_at: ISO.string(Date()),
                                                  groups: settings.groups.map(\.rawValue).sorted(), routes: settings.includeRoutes)
            if !pendingTypes.isEmpty {
                checkpoint.checkpoint?.status = "scan_partial"
                checkpoint.checkpoint?.pending_types = pendingTypes.sorted()
            }
            let bytes = try await uploader.send(checkpoint)
            record.bytes += bytes
            record.requests += 1
            try await ensureCurrent()
            if pendingTypes.isEmpty {
                record.outcome = .riuscito
            } else {
                record.outcome = .parziale
                record.message = Self.pendingAuthorizationMessage
                await MainActor.run {
                    // A previously complete namespace is no longer complete if
                    // an explicit authorization error now blocks one of its types.
                    guard AppSettings.shared.isCurrent(settings) else { return }
                    UserDefaults.standard.set(false, forKey: AppSettings.Keys.historyComplete)
                }
            }
        } catch {
            classify(error, into: &record)
        }
        record.duration = Date().timeIntervalSince(start)
        return record
    }

    private func classify(_ error: Error, into record: inout SyncRecord) {
        let delivered = record.requests > 0
        if let hk = error as? HKError, hk.code == .errorDatabaseInaccessible {
            record.outcome = delivered ? .parziale : .inAttesa
            record.message = String(localized: "In attesa dello sblocco dell'iPhone")
        } else if isCancellation(error) {
            record.outcome = delivered ? .parziale : .interrotto
            record.message = String(localized: "Invio interrotto: riprenderà dal punto in cui si è fermato.")
        } else {
            record.outcome = delivered ? .parziale : .errore
            // Never copy arbitrary server/HealthKit error bodies into public logs.
            record.message = (error as? Failure)?.localizedDescription ?? DiagLog.describe(error)
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let upload = error as? UploadError, case .cancelled = upload { return true }
        return false
    }

    /// Build one serialized record at a time. In particular, full GPS/quantity
    /// series cannot accumulate across a whole 500-record HealthKit page.
    private func sendPage(_ samples: [HKSample], deleted: [String], entry: CatalogEntry,
                          uploader: Uploader, record: inout SyncRecord) async throws {
        var batch = Batch()
        var encodedUpperBound = 0
        for sample in samples {
            try await ensureCurrent()
            if entry.kind.isExtended {
                try await send(&batch, uploader: uploader, record: &record)
                encodedUpperBound = 0
                try await sendExtended(sample, uploader: uploader, record: &record)
                continue
            }
            var one = Batch()
            try await one.add([sample], entry: entry, includeRoutes: settings.includeRoutes)
            guard one.recordCount == 1 else { throw Failure.invalidRecord }
            // Summing single-record envelopes deliberately overestimates bytes,
            // and avoids re-encoding all earlier records for every new sample.
            let oneSize = try Self.encodedSize(one.makePayload(settings: settings))
            if oneSize > Self.maxPayloadBytes {
                try await send(&batch, uploader: uploader, record: &record)
                encodedUpperBound = 0
                let payload = try JSONDecoder().decode(WireJSON.self, from: RecordFrames.encode(one.makePayload(settings: settings)))
                guard let section = payload.object?.first(where: { key, value in
                    guard ["campioni", "categorie", "allenamenti", "ecg", "audiogrammi", "stati_d_animo", "correlazioni"].contains(key) else { return false }
                    if case .array(let rows) = value { return rows.count == 1 }
                    return false
                }), case .array(let rows) = section.value, let row = rows.first else { throw Failure.invalidRecord }
                try await sendRecordData(RecordFrames.encode(row), section: section.key,
                                         uploader: uploader, record: &record)
                continue
            }
            if batch.count + one.count > Self.maxPerPost || encodedUpperBound + oneSize > Self.maxPayloadBytes {
                try await send(&batch, uploader: uploader, record: &record)
                batch = one
                encodedUpperBound = oneSize
            } else {
                batch = batch.merging(one)
                encodedUpperBound += oneSize
            }
            if entry.kind == .workout && settings.includeRoutes || batch.count >= Self.maxPerPost ||
                (entry.kind == .electrocardiogram && batch.count >= Self.maxECGPerPost) {
                try await send(&batch, uploader: uploader, record: &record)
                encodedUpperBound = 0
            }
        }
        for uuid in deleted {
            var one = Batch()
            one.deleted = [uuid]
            let oneSize = try Self.encodedSize(one.makePayload(settings: settings))
            if batch.count + 1 > Self.maxPerPost || encodedUpperBound + oneSize > Self.maxPayloadBytes {
                try await send(&batch, uploader: uploader, record: &record)
                encodedUpperBound = 0
            }
            batch.deleted.append(uuid)
            encodedUpperBound += oneSize
            if batch.count >= Self.maxPerPost {
                try await send(&batch, uploader: uploader, record: &record)
                encodedUpperBound = 0
            }
        }
        try await send(&batch, uploader: uploader, record: &record)
    }

    static func encodedSize(_ payload: Payload) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload).count
    }

    private func send(_ batch: inout Batch, uploader: Uploader, record: inout SyncRecord) async throws {
        guard !batch.isEmptyPayload else { return }
        try await ensureCurrent()
        let payload = batch.makePayload(settings: settings)
        guard batch.count <= Self.maxPerPost, try Self.encodedSize(payload) <= Self.maxPayloadBytes else {
            throw Failure.oversizedRecord
        }
        let bytes = try await uploader.send(payload)
        record.samples += batch.recordCount
        record.deleted += batch.deleted.count
        record.bytes += bytes
        record.requests += 1
        batch = Batch()
        try await ensureCurrent()
    }

    /// A route has its own lifecycle after the workout is saved. Keep its own
    /// cursor; on a change replay workouts using a separately persisted cursor.
    /// The route cursor advances only after every workout page was acknowledged.
    private func reconcileRoutes(uploader: Uploader, record: inout SyncRecord,
                                 status: inout SyncProgress, progress: @escaping Progress) async throws {
        let store = AnchorStore.shared
        let destination = settings.destinationID
        var pending: RouteReconciliation?
        if let data = try store.data(for: AnchorStore.routePendingID, destination: destination) {
            pending = try JSONDecoder().decode(RouteReconciliation.self, from: data)
        }
        if pending == nil {
            var anchor = try store.anchor(for: AnchorStore.routeAnchorID, destination: destination)
            var changed = anchor == nil // GPS enabled for the first time: backfill.
            while true {
                try await ensureCurrent()
                let query = HKAnchoredObjectQueryDescriptor(
                    predicates: [.sample(type: HKSeriesType.workoutRoute())], anchor: anchor, limit: Self.maxPerPost)
                let result = try await query.result(for: Health.store)
                if !result.addedSamples.isEmpty || !result.deletedObjects.isEmpty { changed = true }
                anchor = result.newAnchor
                if result.addedSamples.count + result.deletedObjects.count < Self.maxPerPost { break }
            }
            guard let anchor else { throw Failure.invalidRecord }
            let archived = try AnchorStore.archive(anchor)
            if !changed {
                try await ensureCurrent()
                try store.commit([AnchorStore.routeAnchorID: archived], destination: destination)
                return
            }
            let created = RouteReconciliation(targetAnchor: archived)
            pending = created
            try await ensureCurrent()
            try store.commit([AnchorStore.routePendingID: JSONEncoder().encode(created)], destination: destination)
        }
        guard var reconciliation = pending,
              let entry = HealthCatalog.entries(in: [.allenamenti]).first(where: { $0.kind == .workout }),
              let type = entry.sampleType else { throw Failure.invalidRecord }
        var anchor: HKQueryAnchor?
        if let data = reconciliation.workoutAnchor {
            anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
            guard anchor != nil else { throw CocoaError(.coderReadCorrupt) }
        }
        while true {
            try await ensureCurrent()
            let query = HKAnchoredObjectQueryDescriptor(predicates: [.sample(type: type)], anchor: anchor, limit: 1)
            let result = try await query.result(for: Health.store)
            try await sendPage(result.addedSamples, deleted: result.deletedObjects.map(\.uuid.uuidString),
                               entry: entry, uploader: uploader, record: &record)
            let archived = try AnchorStore.archive(result.newAnchor)
            reconciliation.workoutAnchor = archived
            try await ensureCurrent()
            if result.addedSamples.count + result.deletedObjects.count < 1 {
                try store.commit([AnchorStore.routeAnchorID: reconciliation.targetAnchor,
                                  entry.id: archived], destination: destination,
                                 removing: [AnchorStore.routePendingID])
                break
            }
            try store.commit([AnchorStore.routePendingID: JSONEncoder().encode(reconciliation)], destination: destination)
            anchor = result.newAnchor
            status.samplesSent = record.samples + record.deleted
            status.blocksSent = record.requests
            await progress(status)
        }
    }

    static func pageLimit(_ entry: CatalogEntry, routes: Bool) -> Int {
        switch entry.kind {
        case .workout: routes ? 1 : 100
        case .electrocardiogram: maxECGPerPost
        case .audiogram: 100
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
    var correlations: [CorrelationRecord] = []
    var deleted: [String] = []
    var characteristics: Characteristics?

    var recordCount: Int {
        quantities.count + categories.count + workouts.count + ecgs.count + audiograms.count + moods.count + correlations.count
    }

    var count: Int { recordCount + deleted.count }

    var isEmptyPayload: Bool { count == 0 && characteristics == nil }

    mutating func add(_ samples: [HKSample], entry: CatalogEntry, includeRoutes: Bool) async throws {
        switch entry.kind {
        case .quantity:
            guard let unit = entry.unit else { return }
            for case let s as HKQuantitySample in samples { quantities.append(try await Serializer.quantity(s, unit: unit, store: Health.store)) }
        case .category:
            for case let s as HKCategorySample in samples { categories.append(Serializer.category(s)) }
        case .workout:
            for case let w as HKWorkout in samples {
                workouts.append(try await Serializer.workout(w, store: Health.store, includeRoute: includeRoutes))
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
        case .correlation:
            for case let c as HKCorrelation in samples { correlations.append(Serializer.correlation(c)) }
        case .heartbeatSeries, .assessment, .visionPrescription, .medicationDoseEvent:
            // These records use the same page/anchor logic through ExtendedSync.
            throw SyncJob.Failure.invalidRecord
        }
    }

    func merging(_ other: Batch) -> Batch {
        var next = self
        next.quantities += other.quantities
        next.categories += other.categories
        next.workouts += other.workouts
        next.ecgs += other.ecgs
        next.audiograms += other.audiograms
        next.moods += other.moods
        next.correlations += other.correlations
        next.deleted += other.deleted
        if let value = other.characteristics { next.characteristics = value }
        return next
    }

    func makePayload(settings: SettingsSnapshot) -> Payload {
        Payload(
            dispositivo: Uploader.deviceModel,
            inviato: ISO.string(Date()),
            campioni: quantities.isEmpty ? nil : quantities,
            categorie: categories.isEmpty ? nil : categories,
            allenamenti: workouts.isEmpty ? nil : workouts,
            ecg: ecgs.isEmpty ? nil : ecgs,
            audiogrammi: audiograms.isEmpty ? nil : audiograms,
            stati_d_animo: moods.isEmpty ? nil : moods,
            correlazioni: correlations.isEmpty ? nil : correlations,
            eliminati: deleted.isEmpty ? nil : deleted,
            caratteristiche: characteristics,
            installation_id: settings.installationID,
            destination_id: settings.destinationID)
    }
}

/// Prova di connessione: POST di {"app":"salute-libera","versione":1,"prova":true}.
enum ConnectionTest {
    static func run(endpoint: String, token: String, gzip: Bool) async -> Result<Int, UploadError> {
        guard let url = AppSettings.validURL(endpoint) else {
            return .failure(.invalidEndpoint)
        }
        let uploader = Uploader(endpoint: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), gzip: gzip)
        do {
            let snapshot = await MainActor.run { AppSettings.shared.snapshot }
            let payload = TestPayload(installation_id: snapshot.installationID, destination_id: snapshot.destinationID)
            let bytes = try await uploader.send(payload, attempts: 1)
            return .success(bytes)
        } catch let e as UploadError {
            return .failure(e)
        } catch {
            return .failure(.network((error as NSError).code))
        }
    }
}
