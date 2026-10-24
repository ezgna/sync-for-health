import Foundation

// Synthetic adapters only. Production SyncJob/Batch/Payload/AnchorStore are
// extracted by the runner without reimplementing their state machine.
enum DataGroup: String, Sendable { case corpo, cuore, allenamenti, ecg, attivita, glicemia }
enum EntryKind: Equatable, Sendable {
    case quantity(unit: String), category, correlation, workout, electrocardiogram, audiogram, stateOfMind
    case heartbeatSeries, assessment, visionPrescription, medicationDoseEvent
    var isExtended: Bool {
        switch self {
        case .heartbeatSeries, .assessment, .visionPrescription, .medicationDoseEvent: true
        default: false
        }
    }
}
struct CatalogEntry: Sendable {
    var id: String
    var kind: EntryKind
    var sampleType: HKSampleType? { .init(id: id) }
    var unit: HKUnit? { .init() }
    var immediate: Bool { true }
    var canObserve: Bool {
        switch kind {
        case .correlation, .visionPrescription: false
        default: true
        }
    }
}
struct HKSampleType: Sendable, Hashable { var id: String; var identifier: String { id } }
struct HKUnit: Sendable {}
final class HKQueryAnchor: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }
    let offset: Int
    init(offset: Int) { self.offset = offset }
    required init?(coder: NSCoder) { offset = coder.decodeInteger(forKey: "offset") }
    func encode(with coder: NSCoder) { coder.encode(offset, forKey: "offset") }
}
class HKSample: @unchecked Sendable { var uuid = UUID() }
class HKQuantitySample: HKSample, @unchecked Sendable { var text = "" }
class HKCategorySample: HKSample, @unchecked Sendable {}
class HKCorrelation: HKSample, @unchecked Sendable {}
class HKWorkout: HKSample, @unchecked Sendable {}
class HKElectrocardiogram: HKSample, @unchecked Sendable {}
class HKAudiogramSample: HKSample, @unchecked Sendable {}
class HKStateOfMind: HKSample, @unchecked Sendable {}
class HKExtraSample: HKSample, @unchecked Sendable { var text = "synthetic-extra"; var section = "valutazioni" }
struct FakeSnapshotRow: Encodable, Sendable { var id: String; var value: String }
struct HKDeletedObject: Sendable { var uuid: UUID }
struct HKError: Error {
    enum Code { case errorDatabaseInaccessible, errorAuthorizationDenied, errorAuthorizationNotDetermined, errorRequiredAuthorizationDenied }
    var code: Code
}
enum HKSeriesType { static func workoutRoute() -> HKSampleType { .init(id: "routes") } }
enum HKObjectType {
    static func activitySummaryType() -> HKSampleType { .init(id: "activity-summary") }
    static func userAnnotatedMedicationType() -> HKSampleType { .init(id: "medication-catalog") }
}
enum AppEnvironment { static var isDemo = false }
@MainActor final class AppSettings {
    static let shared = AppSettings()
    var current = true
    var syncEnabled = true
    var includeRoutes = false
    var settings = SettingsSnapshot()
    var snapshot: SettingsSnapshot {
        var copy = settings
        copy.syncEnabled = syncEnabled
        copy.includeRoutes = includeRoutes
        return copy
    }
    enum Keys { static let historyComplete = "synthetic.history" }
    func isCurrent(_ snapshot: SettingsSnapshot) -> Bool { current && syncEnabled && snapshot.syncEnabled && settings.revision == snapshot.revision }
}
struct SettingsSnapshot: Sendable {
    var endpoint: URL? = URL(string: "https://synthetic.invalid/ingest")
    var token = "synthetic-not-a-real-token"
    var gzip = false
    var includeRoutes = false
    var groups: Set<DataGroup> = [.cuore]
    var destinationID = "synthetic-destination-a"
    var installationID = "synthetic-installation"
    var revision = UUID()
    var syncEnabled = true
    var diagnosticsEnabled = false
}
struct SyncRecord: Sendable {
    enum Outcome: String, Sendable { case riuscito, errore, nienteDaInviare, interrotto, parziale, inAttesa }
    enum Trigger: String, Sendable { case manuale, automatico, background, prova, storico }
    var date: Date; var samples: Int; var deleted: Int; var outcome: Outcome
    var trigger: Trigger; var message: String?; var duration: Double; var bytes: Int; var requests: Int
}
struct SyncProgress: Sendable { var typeIndex = 0; var typeCount = 0; var typeIdentifier: String?; var samplesSent = 0; var blocksSent = 0 }
enum UploadError: Error { case cancelled, network }
enum DiagLog { static func describe(_ error: Error) -> String { "synthetic_error" }; static func warning(_ a: String, _ b: String) {}; static func info(_ a: String, _ b: String) {} }
enum HealthCatalog {
    static var list: [CatalogEntry] = []
    static func entries(in groups: Set<DataGroup>) -> [CatalogEntry] {
        list.filter { entry in entry.kind == .workout ? groups.contains(.allenamenti) : !groups.intersection([.corpo, .cuore, .ecg]).isEmpty }
    }
}
enum Storage { static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
struct FakeEvent { var sample: HKSample?; var deleted: UUID? }
final class FakeStore {
    var events: [String: [FakeEvent]] = [:]
    var calls: [(String, Int, Int)] = []
    var routeAvailable = false
    var birthDate = "2000-01-01"
    var pendingDisables: [(Bool, Error?) -> Void] = []
    var pendingEnables: [(String, (Bool, Error?) -> Void)] = []
    var observerEvents: [String] = []
    var observedTypes: [String] = []
    var activityRows: [FakeSnapshotRow] = []
    var medicationRows: [FakeSnapshotRow] = []
    var snapshotError = false
    var activityError: Error?
    var medicationError: Error?
    var queryErrors: [String: Error] = [:]
    var snapshotCalls = 0
    func disableAllBackgroundDelivery(completion: @escaping (Bool, Error?) -> Void) { pendingDisables.append(completion); observerEvents.append("disable") }
    func enableBackgroundDelivery(for type: HKSampleType, frequency: FakeFrequency, completion: @escaping (Bool, Error?) -> Void) { pendingEnables.append((type.id, completion)); observerEvents.append("enable:" + type.id) }
    func execute(_ query: HKObserverQuery) {
        observerEvents.append("observe")
        observedTypes = query.queryDescriptors.map { $0.sampleType.identifier }
    }
    func stop(_ query: HKObserverQuery) { observerEvents.append("stop") }
    func reset() {
        events = [:]; calls = []; routeAvailable = false
        activityRows = []; medicationRows = []; snapshotError = false; snapshotCalls = 0
        activityError = nil; medicationError = nil; queryErrors = [:]
    }
}
enum Health { static let isAvailable = true; static let store = FakeStore() }
enum FakeFrequency { case immediate, hourly }
struct HKQueryDescriptor { var sampleType: HKSampleType; var predicate: NSPredicate? }
final class HKObserverQuery {
    let queryDescriptors: [HKQueryDescriptor]
    init(queryDescriptors: [HKQueryDescriptor], updateHandler: @escaping (HKObserverQuery, Set<HKSampleType>?, @escaping () -> Void, Error?) -> Void) {
        self.queryDescriptors = queryDescriptors
    }
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var isProtectedDataAvailable = true
}
@MainActor final class SyncCenter {
    static let shared = SyncCenter()
    var demoFinishedCount = 0
    var realFinishedCount = 0
    func began(_ trigger: SyncRecord.Trigger) {}
    func progressed(_ progress: SyncProgress) {}
    func finished(_ record: SyncRecord) { realFinishedCount += 1 }
    func finishedDemo() { demoFinishedCount += 1 }
}
@MainActor final class SyncLog {
    static let shared = SyncLog()
    var records: [SyncRecord] = []
    func add(_ record: SyncRecord) { records.append(record) }
}
final class TestDefaults {
    static let standard = TestDefaults()
    var values: [String: Bool] = [:]
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}
enum BackgroundTasks { static func scheduleAll() {} }
actor DiagShipper {
    static let shared = DiagShipper()
    func shipIfDue() {}
}

struct HKSamplePredicate {
    var id: String
    static func sample(type: HKSampleType) -> Self { .init(id: type.id) }
}
struct HKAnchoredObjectQueryDescriptor {
    var predicates: [HKSamplePredicate]; var anchor: HKQueryAnchor?; var limit: Int
    struct Result { var addedSamples: [HKSample]; var deletedObjects: [HKDeletedObject]; var newAnchor: HKQueryAnchor }
    func result(for store: FakeStore) async throws -> Result {
        let id = predicates[0].id, start = anchor?.offset ?? 0
        store.calls.append((id, start, limit))
        if let error = store.queryErrors[id] { throw error }
        let all = store.events[id] ?? [], page = Array(all.dropFirst(start).prefix(limit))
        return Result(addedSamples: page.compactMap(\.sample), deletedObjects: page.compactMap { $0.deleted.map { .init(uuid: $0) } }, newAnchor: .init(offset: min(all.count, start + page.count)))
    }
}
@MainActor final class FakeHTTP {
    static let shared = FakeHTTP()
    var requests: [Payload] = []
    var wireRequests: [WireEnvelope] = []
    var failures: Set<Int> = []
    var calls = 0
    var changeSettingsAfterCall: Int?
    var suspendCalls: Set<Int> = []
    var waitingUploads: [Int: CheckedContinuation<Void, Never>] = [:]
    func reset() { requests = []; wireRequests = []; failures = []; calls = 0; changeSettingsAfterCall = nil; suspendCalls = []; waitingUploads = [:] }
}
struct Uploader: Sendable {
    var endpoint: URL; var token: String; var gzip: Bool
    static let deviceModel = "SYNTHETIC"
    @MainActor func send(_ payload: Payload) async throws -> Int {
        let http = FakeHTTP.shared
        http.calls += 1
        let call = http.calls
        if http.suspendCalls.contains(call) {
            await withCheckedContinuation { http.waitingUploads[call] = $0 }
            try Task.checkCancellation()
        }
        if http.failures.contains(call) { throw UploadError.network }
        http.requests.append(payload)
        if http.changeSettingsAfterCall == http.calls { await MainActor.run { AppSettings.shared.current = false } }
        return try SyncJob.encodedSize(payload)
    }
    @MainActor func send(_ envelope: WireEnvelope) async throws -> Int {
        let http = FakeHTTP.shared
        http.calls += 1
        let call = http.calls
        if http.suspendCalls.contains(call) {
            await withCheckedContinuation { http.waitingUploads[call] = $0 }
            try Task.checkCancellation()
        }
        if http.failures.contains(call) { throw UploadError.network }
        http.wireRequests.append(envelope)
        if http.changeSettingsAfterCall == http.calls { AppSettings.shared.current = false }
        return try RecordFrames.encode(envelope).count
    }
}
enum ExtendedHealth {
    struct Extra: Encodable, Sendable { let uuid: String; let value: String; let section: String }
    static func sample(_ sample: HKSample, store: FakeStore) async throws -> Extra {
        guard let extra = sample as? HKExtraSample else { throw SyncJob.Failure.invalidRecord }
        return Extra(uuid: extra.uuid.uuidString, value: extra.text, section: extra.section)
    }
    static func activitySummaries(store: FakeStore, timeZone: TimeZone) async throws -> [FakeSnapshotRow] {
        store.snapshotCalls += 1
        if let error = store.activityError { throw error }
        if store.snapshotError { throw UploadError.network }
        return store.activityRows
    }
    static func medications(store: FakeStore) async throws -> [FakeSnapshotRow] {
        store.snapshotCalls += 1
        if let error = store.medicationError { throw error }
        if store.snapshotError { throw UploadError.network }
        return store.medicationRows
    }
}
enum Serializer {
    static func characteristics(store: FakeStore) -> Characteristics { Characteristics(data_di_nascita: store.birthDate) }
    static func quantity(_ s: HKQuantitySample, unit: HKUnit, store: FakeStore) async throws -> QuantityRecord {
        .init(uuid: s.uuid.uuidString, tipo: "q", valore: 1, unita: "count", inizio: "x", fine: "x", fonte: "fake", metadati: ["synthetic": s.text])
    }
    static func category(_ s: HKCategorySample) -> CategoryRecord { .init(uuid: s.uuid.uuidString, tipo: "c", valore: 1, inizio: "x", fine: "x", fonte: "fake") }
    static func correlation(_ s: HKCorrelation) -> CorrelationRecord { .init(uuid: s.uuid.uuidString, tipo: "correlation", inizio: "x", fine: "x", fonte: "fake", membri: []) }
    static func workout(_ s: HKWorkout, store: FakeStore, includeRoute: Bool) async throws -> WorkoutRecord {
        .init(uuid: s.uuid.uuidString, attivita: "walk", inizio: "x", fine: "x", durata_s: 1, fonte: "fake", percorso: includeRoute ? (store.routeAvailable ? [.init(lat: 0, lon: 0, alt: 0, t: "x")] : []) : nil)
    }
    static func electrocardiogram(_ s: HKElectrocardiogram, store: FakeStore) async throws -> ECGRecord { .init(uuid: s.uuid.uuidString, inizio: "x", classificazione: "x") }
    static func audiogram(_ s: HKAudiogramSample) -> AudiogramRecord { .init(uuid: s.uuid.uuidString, inizio: "x", fine: "x", fonte: "fake", punti: []) }
    static func stateOfMind(_ s: HKStateOfMind) -> StateOfMindRecord { .init(uuid: s.uuid.uuidString, inizio: "x", tipo: "x", valenza: 0, classificazione: "x", etichette: [], associazioni: [], fonte: "fake") }
}
func added(_ count: Int) -> [FakeEvent] { (0..<count).map { _ in .init(sample: HKQuantitySample(), deleted: nil) } }
func deleted(_ count: Int) -> [FakeEvent] { (0..<count).map { _ in .init(sample: nil, deleted: UUID()) } }
@MainActor func job(destination: String = "synthetic-destination-a", groups: Set<DataGroup> = [.cuore], routes: Bool = false) -> SyncJob {
    var settings = SettingsSnapshot(includeRoutes: routes, groups: groups, destinationID: destination)
    settings.revision = AppSettings.shared.settings.revision
    return .init(settings: settings, trigger: .manuale)
}
func cursor(_ type: String, destination: String = "synthetic-destination-a") -> Int? { try! AnchorStore.shared.anchor(for: type, destination: destination)?.offset }
@MainActor func reset(_ entries: [CatalogEntry]) {
    AppEnvironment.isDemo = false
    try! AnchorStore.shared.reset()
    AppSettings.shared.current = true
    AppSettings.shared.syncEnabled = true
    AppSettings.shared.includeRoutes = false
    AppSettings.shared.settings = SettingsSnapshot()
    TestDefaults.standard.values = [:]
    SyncLog.shared.records = []
    FakeHTTP.shared.reset()
    Health.store.reset()
    HealthCatalog.list = entries
}
var results: [String: Bool] = [:]
func check(_ condition: Bool, _ name: String) { precondition(condition, name); results[name] = true }
@MainActor func spin(_ predicate: () -> Bool) async {
    for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
    preconditionFailure("synthetic callback was not reached")
}
@main struct Main {
    @MainActor static func main() async throws {
        let q = CatalogEntry(id: "q", kind: .quantity(unit: "count")), workout = CatalogEntry(id: "workout", kind: .workout)
        reset([q]); Health.store.events["q"] = added(1001)
        let full = await job().run { _ in }
        check(full.samples == 1001 && full.requests == 4 && cursor("q") == 1001, "bounded_full_history_and_checkpoint")
        check(FakeHTTP.shared.requests.allSatisfy { $0.installation_id != nil && $0.destination_id != nil }, "v2_identity_on_every_post")
        check(FakeHTTP.shared.requests.last?.checkpoint?.status == "scan_complete", "checkpoint_only_after_all_pages")
        reset([q]); Health.store.events["q"] = deleted(1001)
        let deletions = await job().run { _ in }
        check(deletions.deleted == 1001 && cursor("q") == 1001, "deletion_only_pagination")
        reset([q]); Health.store.events["q"] = added(500)
        _ = await job().run { _ in }
        check(Health.store.calls.map { $0.1 } == [0, 500] && cursor("q") == 500, "final_empty_page_is_committed")
        reset([q]); Health.store.events["q"] = added(1001); FakeHTTP.shared.failures = [2]
        let failed = await job().run { _ in }
        check(failed.samples == 500 && cursor("q") == 500 && FakeHTTP.shared.requests.allSatisfy { $0.checkpoint == nil }, "partial_failure_keeps_only_acked_page")
        FakeHTTP.shared.failures = []; FakeHTTP.shared.requests = []
        let resumed = await job().run { _ in }
        check(resumed.samples == 501 && cursor("q") == 1001, "resume_from_durable_cursor")
        reset([q]); Health.store.events["q"] = added(1); FakeHTTP.shared.failures = [1]
        _ = await job().run { _ in }
        check(cursor("q") == nil, "first_failed_post_does_not_advance")
        reset([q]); Health.store.events["q"] = added(20)
        _ = await job().run { _ in }; FakeHTTP.shared.reset()
        let moved = await job(destination: "synthetic-destination-b").run { _ in }
        check(moved.samples == 20 && cursor("q", destination: "synthetic-destination-b") == 20, "destination_namespace_replays_history")
        reset([q]); Health.store.events["q"] = added(1001); FakeHTTP.shared.changeSettingsAfterCall = 1
        _ = await job().run { _ in }
        check(cursor("q") == nil && FakeHTTP.shared.requests.count == 1, "settings_change_stops_and_prevents_cursor_commit")
        reset([q]); let big = (0..<3).map { _ -> FakeEvent in let sample = HKQuantitySample(); sample.text = String(repeating: "a", count: 4 * 1024 * 1024); return .init(sample: sample, deleted: nil) }
        Health.store.events["q"] = big; FakeHTTP.shared.failures = [2]
        _ = await job().run { _ in }
        check(cursor("q") == nil && FakeHTTP.shared.requests.count == 1, "byte_split_failure_replays_entire_page")
        check(try FakeHTTP.shared.requests.allSatisfy { try SyncJob.encodedSize($0) <= SyncJob.maxPayloadBytes }, "each_post_within_byte_limit")
        FakeHTTP.shared.reset(); _ = await job().run { _ in }
        check(cursor("q") == 3 && FakeHTTP.shared.requests.filter { $0.campioni != nil }.count == 3, "byte_split_page_commits_after_all_chunks")
        reset([q]); let nearLimit = HKQuantitySample(); nearLimit.text = String(repeating: "a", count: SyncJob.maxPayloadBytes - 1000)
        Health.store.events["q"] = [.init(sample: nearLimit, deleted: nil)] + deleted(100)
        let mixed = await job().run { _ in }
        check(mixed.outcome == .riuscito && mixed.deleted == 100 && cursor("q") == 101, "deletions_after_near_limit_record_split_before_byte_cap")
        check(try FakeHTTP.shared.requests.allSatisfy { try SyncJob.encodedSize($0) <= SyncJob.maxPayloadBytes }, "mixed_added_deleted_posts_within_byte_limit")
        let largeIntegerJSON = Data("{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"integer\":18446744073709551615,\"fraction\":1.123456789,\"flag\":true}".utf8)
        let integerFrames = try RecordFrames(data: largeIntegerJSON, section: "valutazioni",
                                             installation: "synthetic", destination: "synthetic", device: "synthetic", sentAt: "x")
        let integerEnvelope = try JSONSerialization.jsonObject(with: RecordFrames.encode(Array(integerFrames)[0])) as! [String: Any]
        let integerRow = (integerEnvelope["valutazioni"] as! [[String: Any]])[0]
        check((integerRow["integer"] as? NSNumber)?.uint64Value == UInt64.max,
              "wire_transport_preserves_unsigned_integer_extreme")
        check(integerRow["fraction"] as? Double == 1.123456789 && integerRow["flag"] as? Bool == true,
              "wire_transport_preserves_fraction_and_boolean_types")
        reset([q]); let oversized = HKQuantitySample(); oversized.text = String(repeating: "a", count: 9 * 1024 * 1024)
        Health.store.events["q"] = [.init(sample: oversized, deleted: nil)]
        let tooBig = await job().run { _ in }
        check(tooBig.outcome == .riuscito && cursor("q") == 1 && FakeHTTP.shared.wireRequests.count > 1,
              "oversized_single_record_is_fragmented_without_skip")
        check(try FakeHTTP.shared.wireRequests.allSatisfy { try RecordFrames.encode($0).count <= SyncJob.maxPayloadBytes },
              "every_record_fragment_within_byte_limit")
        var assembled = Data()
        for envelope in FakeHTTP.shared.wireRequests {
            guard case .array(let fragments) = envelope.fields["frammenti"],
                  let fragment = fragments.first?.object,
                  let encoded = fragment["data_base64"]?.string,
                  let part = Data(base64Encoded: encoded) else { preconditionFailure("missing fragment bytes") }
            assembled.append(part)
        }
        let assembledRow = try JSONSerialization.jsonObject(with: assembled) as! [String: Any]
        check(assembledRow["uuid"] as? String == oversized.uuid.uuidString
                && (assembledRow["metadati"] as? [String: String])?["synthetic"] == oversized.text,
              "fragment_bytes_reassemble_the_entire_original_record")
        reset([q]); Health.store.events["q"] = [.init(sample: oversized, deleted: nil)]; FakeHTTP.shared.failures = [2]
        let fragmentFailed = await job().run { _ in }
        check(fragmentFailed.outcome == .parziale && cursor("q") == nil && FakeHTTP.shared.wireRequests.count == 1
                && FakeHTTP.shared.requests.allSatisfy { $0.checkpoint == nil },
              "fragment_failure_keeps_page_cursor_and_checkpoint_uncommitted")
        FakeHTTP.shared.reset()
        let fragmentResumed = await job().run { _ in }
        check(fragmentResumed.outcome == .riuscito && cursor("q") == 1 && fragmentResumed.samples == 1,
              "fragment_failure_resends_full_original_record")

        let extra = CatalogEntry(id: "extra", kind: .assessment)
        reset([extra]); Health.store.events["extra"] = [.init(sample: HKExtraSample(), deleted: nil)]
        let extraResult = await job().run { _ in }
        check(extraResult.samples == 1 && cursor("extra") == 1
                && FakeHTTP.shared.wireRequests.first?.fields["valutazioni"] != nil,
              "extended_sample_uses_production_page_and_transport")
        reset([extra]); Health.store.events["extra"] = [.init(sample: HKExtraSample(), deleted: nil)]; FakeHTTP.shared.failures = [1]
        _ = await job().run { _ in }
        check(cursor("extra") == nil && FakeHTTP.shared.requests.allSatisfy { $0.checkpoint == nil },
              "extended_sample_failed_ack_does_not_advance_anchor")

        reset([]); Health.store.activityRows = (0..<175).map { .init(id: String($0), value: "original") }
        let snapshots = await job(groups: [.attivita]).run { _ in }
        check(snapshots.samples == 1 && FakeHTTP.shared.wireRequests.count == 1,
              "daily_snapshot_contains_all_rows_beyond_old_prefix")
        if case .array(let records) = FakeHTTP.shared.wireRequests[0].fields["riepiloghi_attivita"],
           case .array(let days) = records[0].object?["records"] {
            check(days.count == 175, "all_accessible_daily_rows_in_single_atomic_record")
        } else { preconditionFailure("missing activity snapshot") }
        FakeHTTP.shared.reset()
        _ = await job(groups: [.attivita]).run { _ in }
        check(FakeHTTP.shared.wireRequests.isEmpty && Health.store.snapshotCalls == 2,
              "unchanged_snapshot_rereads_healthkit_without_resending")
        Health.store.activityRows[174].value = "edited"; FakeHTTP.shared.reset()
        _ = await job(groups: [.attivita]).run { _ in }
        check(FakeHTTP.shared.wireRequests.count == 1, "edits_to_later_daily_rows_replace_snapshot")
        Health.store.activityRows = []; FakeHTTP.shared.reset()
        _ = await job(groups: [.attivita]).run { _ in }
        check(FakeHTTP.shared.wireRequests.count == 1, "removed_daily_rows_send_explicit_empty_snapshot")
        reset([]); Health.store.medicationRows = [.init(id: "med", value: "original")]; FakeHTTP.shared.failures = [1]
        _ = await job(groups: [.glicemia]).run { _ in }
        check(try AnchorStore.shared.data(for: "healthbridge.snapshot.medications.digest.v1", destination: "synthetic-destination-a") == nil,
              "failed_medication_snapshot_does_not_commit_digest")
        FakeHTTP.shared.reset()
        _ = await job(groups: [.glicemia]).run { _ in }
        check(FakeHTTP.shared.wireRequests.first?.fields["farmaci"] != nil,
              "medication_snapshot_retries_after_failed_ack")
        reset([]); Health.store.snapshotError = true
        let snapshotQueryFailed = await job(groups: [.attivita]).run { _ in }
        check(snapshotQueryFailed.outcome == .errore && FakeHTTP.shared.requests.isEmpty && FakeHTTP.shared.wireRequests.isEmpty,
              "snapshot_query_error_is_not_false_empty_success")
        let blocked = CatalogEntry(id: "vision", kind: .visionPrescription)
        for (code, name) in [(HKError.Code.errorAuthorizationDenied, "denied"),
                             (.errorAuthorizationNotDetermined, "undetermined"),
                             (.errorRequiredAuthorizationDenied, "required_denied")] {
            reset([blocked, q]); Health.store.queryErrors["vision"] = HKError(code: code)
            Health.store.events["q"] = added(1)
            TestDefaults.standard.set(true, forKey: AppSettings.Keys.historyComplete)
            let pending = await job().run { _ in }
            check(pending.outcome == .parziale && cursor("vision") == nil && cursor("q") == 1
                    && FakeHTTP.shared.requests.last?.checkpoint?.status == "scan_partial"
                    && FakeHTTP.shared.requests.last?.checkpoint?.pending_types == ["vision"]
                    && TestDefaults.standard.values[AppSettings.Keys.historyComplete] == false,
                  "explicit_\(name)_permission_continues_other_types_without_false_history_complete")
        }
        reset([blocked, q]); Health.store.events["q"] = added(1)
        let emptyAccessible = await job().run { _ in }
        check(emptyAccessible.outcome == .riuscito && FakeHTTP.shared.requests.last?.checkpoint?.pending_types == nil
                && cursor("vision") == 0, "empty_query_is_not_mislabeled_denied_permission")
        reset([]); Health.store.activityError = HKError(code: .errorAuthorizationDenied)
        Health.store.medicationRows = [.init(id: "med", value: "accessible")]
        let partialActivity = await job(groups: [.attivita, .glicemia]).run { _ in }
        check(partialActivity.outcome == .parziale && FakeHTTP.shared.wireRequests.first?.fields["farmaci"] != nil
                && FakeHTTP.shared.requests.last?.checkpoint?.pending_types == ["activity-summary"],
              "blocked_activity_snapshot_does_not_block_medication_snapshot")
        reset([]); Health.store.medicationError = HKError(code: .errorAuthorizationNotDetermined)
        let partialMedication = await job(groups: [.attivita, .glicemia]).run { _ in }
        check(partialMedication.outcome == .parziale && FakeHTTP.shared.wireRequests.first?.fields["riepiloghi_attivita"] != nil
                && FakeHTTP.shared.requests.last?.checkpoint?.pending_types == ["medication-catalog"],
              "blocked_medication_catalog_keeps_other_snapshot_and_explicit_pending_type")
        reset([q]); Health.store.queryErrors["q"] = HKError(code: .errorDatabaseInaccessible)
        let locked = await job().run { _ in }
        check(locked.outcome == .inAttesa && FakeHTTP.shared.requests.isEmpty,
              "locked_health_database_stops_without_checkpoint")
        reset([q]); Health.store.queryErrors["q"] = CancellationError()
        let cancelledQuery = await job().run { _ in }
        check(cancelledQuery.outcome == .interrotto && FakeHTTP.shared.requests.isEmpty,
              "cancelled_health_query_stops_without_partial_checkpoint")
        reset([q]); Health.store.events["q"] = added(1); FakeHTTP.shared.failures = [2]
        _ = await job().run { _ in }
        check(cursor("q") == 1 && FakeHTTP.shared.requests.allSatisfy { $0.checkpoint == nil }, "checkpoint_failure_preserves_sample_cursor")
        FakeHTTP.shared.reset(); let retryCheckpoint = await job().run { _ in }
        check(retryCheckpoint.samples == 0 && FakeHTTP.shared.requests.count == 1 && FakeHTTP.shared.requests[0].checkpoint != nil, "checkpoint_can_retry_without_resending_samples")
        reset([]); Health.store.birthDate = "2000-01-01"
        _ = await job(groups: [.corpo]).run { _ in }; Health.store.birthDate = "2001-02-03"; FakeHTTP.shared.reset()
        _ = await job(groups: [.corpo]).run { _ in }
        check(FakeHTTP.shared.requests.first?.caratteristiche?.data_di_nascita == "2001-02-03", "characteristics_are_reread_each_scan")
        reset([workout]); Health.store.events["workout"] = [.init(sample: HKWorkout(), deleted: nil)]
        _ = await job(groups: [.allenamenti], routes: true).run { _ in }; FakeHTTP.shared.reset()
        Health.store.events["routes"] = [.init(sample: HKSample(), deleted: nil)]; Health.store.routeAvailable = true
        _ = await job(groups: [.allenamenti], routes: true).run { _ in }
        check(FakeHTTP.shared.requests.contains { $0.allenamenti?.first?.percorso?.count == 1 }, "late_route_triggers_workout_reconciliation")
        FakeHTTP.shared.reset(); Health.store.events["routes"]!.append(.init(sample: nil, deleted: UUID())); Health.store.routeAvailable = false
        _ = await job(groups: [.allenamenti], routes: true).run { _ in }
        check(FakeHTTP.shared.requests.contains { $0.allenamenti?.first?.percorso?.isEmpty == true }, "route_deletion_sends_explicit_empty_route")
        reset([workout]); Health.store.events["workout"] = (0..<3).map { _ in .init(sample: HKWorkout(), deleted: nil) }; FakeHTTP.shared.failures = [2]
        _ = await job(groups: [.allenamenti], routes: true).run { _ in }
        check(try AnchorStore.shared.anchor(for: AnchorStore.routeAnchorID, destination: "synthetic-destination-a") == nil, "route_cursor_waits_for_all_workouts")
        FakeHTTP.shared.reset(); Health.store.calls = []
        _ = await job(groups: [.allenamenti], routes: true).run { _ in }
        check(Health.store.calls.first?.0 == "workout" && Health.store.calls.first?.1 == 1, "route_reconciliation_resumes_saved_workout_cursor")
        check(FakeHTTP.shared.requests.allSatisfy { ($0.allenamenti?.count ?? 0) <= 1 }, "gps_posts_contain_at_most_one_workout")
        // Real atomic file writes and original cache-update order, without HealthKit.
        let missingParent = Storage.directory.appendingPathComponent("missing", isDirectory: true)
        let diskStore = AnchorStore(url: missingParent.appendingPathComponent("state.plist"))
        let data = try AnchorStore.archive(HKQueryAnchor(offset: 123))
        var failedWrite = false
        do { try diskStore.commit(["q": data], destination: "test") } catch { failedWrite = true }
        let failedCursor = try diskStore.anchor(for: "q", destination: "test")
        check(failedWrite && failedCursor == nil, "disk_failure_does_not_advance_cache")
        try FileManager.default.createDirectory(at: missingParent, withIntermediateDirectories: true)
        try diskStore.commit(["q": data], destination: "test")
        let reopened = AnchorStore(url: missingParent.appendingPathComponent("state.plist"))
        check(try reopened.anchor(for: "q", destination: "test")?.offset == 123, "cursor_survives_store_reopen")
        let brokenURL = Storage.directory.appendingPathComponent("broken.plist")
        try Data("synthetic corruption".utf8).write(to: brokenURL)
        let broken = AnchorStore(url: brokenURL); var refusedCorrupt = false
        do { _ = try broken.anchor(for: "q", destination: "test") } catch { refusedCorrupt = true }
        check(refusedCorrupt, "corrupt_cursor_file_fails_closed")
        try broken.reset(); check(try broken.anchor(for: "q", destination: "test") == nil, "explicit_reset_recovers_corrupt_cursor")
        reset([q]); AppEnvironment.isDemo = true; Health.store.events["q"] = added(10)
        let demoResult = await job().run { _ in }
        check(FakeHTTP.shared.requests.isEmpty && Health.store.calls.isEmpty, "demo_never_reads_healthkit_or_sends_http")
        check(demoResult.samples == 0 && demoResult.deleted == 0 && demoResult.bytes == 0 && demoResult.requests == 0 && demoResult.outcome == .interrotto, "demo_is_not_counted_as_successful_sync")
        check(cursor("q") == nil, "demo_does_not_advance_real_cursors")
        AppEnvironment.isDemo = false
        reset([q]); Health.store.events["q"] = added(5)
        FakeHTTP.shared.suspendCalls = [1, 2]
        let oldRevision = AppSettings.shared.settings.revision
        let oldRequest = Task { await SyncCoordinator.shared.request(.manuale) }
        await spin { FakeHTTP.shared.waitingUploads[1] != nil }
        AppSettings.shared.settings.revision = UUID()
        let newRequest = Task { await SyncCoordinator.shared.request(.manuale) }
        // Let the new request observe the old active snapshot and cancel it.
        for _ in 0..<100 { await Task.yield() }
        FakeHTTP.shared.waitingUploads.removeValue(forKey: 1)?.resume()
        await spin { FakeHTTP.shared.waitingUploads[2] != nil }
        await SyncCoordinator.shared.cancelStale(revision: oldRevision)
        FakeHTTP.shared.waitingUploads.removeValue(forKey: 2)?.resume()
        let oldSucceeded = await oldRequest.value
        let newSucceeded = await newRequest.value
        check(!oldSucceeded && newSucceeded, "new_revision_request_restarts_after_cancelled_old_job")
        check(cursor("q") == 5 && FakeHTTP.shared.requests.last?.checkpoint != nil, "delayed_cancel_does_not_cancel_current_revision_job")
        reset([q]); AppEnvironment.isDemo = true
        let demoFinishedBefore = SyncCenter.shared.demoFinishedCount
        let realFinishedBefore = SyncCenter.shared.realFinishedCount
        let demoCoordinatorResult = await SyncCoordinator.shared.request(.manuale)
        check(!demoCoordinatorResult && SyncCenter.shared.demoFinishedCount == demoFinishedBefore + 1 && SyncCenter.shared.realFinishedCount == realFinishedBefore, "coordinator_finishes_demo_without_success_state")
        check(TestDefaults.standard.values[AppSettings.Keys.historyComplete] == nil && SyncLog.shared.records.isEmpty && FakeHTTP.shared.requests.isEmpty, "demo_does_not_mark_history_complete_or_add_real_log")
        AppEnvironment.isDemo = false
        // Delayed HealthKit completions exercise the production observer restart
        // path. No timing assumptions: callbacks are explicitly released below.
        HealthCatalog.list = [q]
        AppSettings.shared.syncEnabled = true
        AppSettings.shared.includeRoutes = false
        HealthBackground.restart(groups: [.cuore])
        await spin { Health.store.pendingDisables.count == 1 }
        HealthBackground.restart(groups: [.corpo])
        check(Health.store.pendingDisables.count == 1 && Health.store.pendingEnables.isEmpty, "observer_restart_waits_for_disable_completion")
        Health.store.pendingDisables.removeFirst()(true, nil)
        await spin { Health.store.pendingDisables.count == 1 }
        check(Health.store.pendingEnables.isEmpty, "stale_observer_generation_is_not_installed")
        Health.store.pendingDisables.removeFirst()(true, nil)
        await spin { Health.store.pendingEnables.count == 1 }
        HealthBackground.restart(groups: [.cuore])
        await Task.yield()
        check(Health.store.pendingDisables.isEmpty, "next_restart_waits_for_inflight_enable_completion")
        Health.store.pendingEnables.removeFirst().1(true, nil)
        await spin { Health.store.pendingDisables.count == 1 }
        Health.store.pendingDisables.removeFirst()(true, nil)
        await spin { Health.store.pendingEnables.count == 1 }
        Health.store.pendingEnables.removeFirst().1(true, nil)
        HealthBackground.stop()
        await spin { Health.store.pendingDisables.count == 1 }
        Health.store.pendingDisables.removeFirst()(true, nil)
        HealthCatalog.list = [q,
            CatalogEntry(id: "vision", kind: .visionPrescription),
            CatalogEntry(id: "correlation", kind: .correlation),
            CatalogEntry(id: "heartbeat", kind: .heartbeatSeries),
            CatalogEntry(id: "assessment", kind: .assessment),
            CatalogEntry(id: "medication-dose", kind: .medicationDoseEvent)]
        Health.store.observedTypes = []
        HealthBackground.restart(groups: [.corpo, .cuore])
        await spin { Health.store.pendingDisables.count == 1 }
        Health.store.pendingDisables.removeFirst()(true, nil)
        for _ in 0..<4 {
            await spin { Health.store.pendingEnables.count == 1 }
            Health.store.pendingEnables.removeFirst().1(true, nil)
        }
        check(Set(Health.store.observedTypes) == Set(["q", "heartbeat", "assessment", "medication-dose"]),
              "observer_excludes_native_unsupported_vision_without_excluding_readable_new_types")
        check(HealthCatalog.entries(in: [.corpo]).contains { $0.kind == .visionPrescription },
              "vision_remains_readable_when_observer_is_unsupported")
        HealthBackground.stop()
        await spin { Health.store.pendingDisables.count == 1 }
        Health.store.pendingDisables.removeFirst()(true, nil)
        let output = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(data: output, encoding: .utf8)!)
    }
}
