import BackgroundTasks
import Foundation
import HealthKit

/// Consegna in background di HealthKit: un'unica HKObserverQuery su tutti i tipi attivi
/// e enableBackgroundDelivery per ciascuno. Il completion handler viene SEMPRE chiamato.
@MainActor
enum HealthBackground {
    private static var query: HKObserverQuery?
    private static var transition: Task<Void, Never>?
    private static var generation = 0

    static func start(groups: Set<DataGroup>) { restart(groups: groups) }

    /// Await the preceding disable operation before installing observers. An old
    /// disable callback can therefore never remove a newly enabled delivery.
    static func restart(groups: Set<DataGroup>) {
        reconfigure(groups: groups)
    }

    static func stop() { reconfigure(groups: nil) }

    private static func reconfigure(groups: Set<DataGroup>?) {
        generation += 1
        let requestedGeneration = generation
        if let query { Health.store.stop(query) }
        query = nil
        let previous = transition
        transition = Task {
            await previous?.value
            guard Health.isAvailable else { return }
            let disabled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                Health.store.disableAllBackgroundDelivery { success, _ in continuation.resume(returning: success) }
            }
            guard disabled else {
                DiagLog.warning("background", "riallineamento background non riuscito")
                return
            }
            guard requestedGeneration == generation, let groups,
                  AppSettings.shared.syncEnabled, !AppEnvironment.isDemo else { return }
            await install(groups: groups, includeRoutes: AppSettings.shared.includeRoutes,
                          requestedGeneration: requestedGeneration)
        }
    }

    private static func install(groups: Set<DataGroup>, includeRoutes: Bool, requestedGeneration: Int) async {
        let entries = HealthCatalog.entries(in: groups)
        // Correlations have no background delivery. Their quantity members wake
        // the coordinator, which also scans correlation records.
        var observed = entries.filter { $0.kind != .correlation }.compactMap { entry in
            entry.sampleType.map { ($0, entry.immediate) }
        }
        if includeRoutes && groups.contains(.allenamenti) {
            observed.append((HKSeriesType.workoutRoute(), true))
        }
        let descriptors = observed.map { HKQueryDescriptor(sampleType: $0.0, predicate: nil) }
        guard !descriptors.isEmpty else { return }
        let q = HKObserverQuery(queryDescriptors: descriptors) { _, _, completion, error in
            let done = CompletionBox(completion)
            guard error == nil else { done.call(); return }
            Task {
                await SyncCoordinator.shared.request(.automatico)
                done.call()
            }
        }
        query = q
        Health.store.execute(q)
        for (type, immediate) in observed {
            guard requestedGeneration == generation else { return }
            let enabled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                Health.store.enableBackgroundDelivery(for: type, frequency: immediate ? .immediate : .hourly) { success, _ in
                    continuation.resume(returning: success)
                }
            }
            if !enabled { DiagLog.warning("background", "consegna in background non attiva per un tipo") }
        }
    }
}

/// Avvolge un completion handler non-Sendable garantendo una sola chiamata.
final class CompletionBox: @unchecked Sendable {
    private var handler: (() -> Void)?
    private let lock = NSLock()

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    func call() {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        h?()
    }
}

/// BGAppRefreshTask (ogni ora circa) e BGProcessingTask (invii lunghi, es. storico completo).
enum BackgroundTasks {
    static let refreshID = (Bundle.main.bundleIdentifier ?? "app.ezgna.healthbridge") + ".refresh"
    static let processingID = (Bundle.main.bundleIdentifier ?? "app.ezgna.healthbridge") + ".processing"

    /// Da chiamare in application(_:didFinishLaunchingWithOptions:).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task, trigger: .background)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            handle(task, trigger: .background)
        }
    }

    private static func handle(_ task: BGTask, trigger: SyncRecord.Trigger) {
        DiagLog.info("background", "task avviato: \(task.identifier)")
        scheduleAll()
        let box = TaskBox(task)
        let work = Task {
            let succeeded = await SyncCoordinator.shared.request(trigger)
            box.complete(success: succeeded && !Task.isCancelled)
        }
        task.expirationHandler = {
            DiagLog.warning("background", "task scaduto: \(task.identifier)")
            work.cancel()
            Task { await SyncCoordinator.shared.cancel() }
            box.complete(success: false)
        }
    }

    static func scheduleAll() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do { try BGTaskScheduler.shared.submit(refresh) } catch {
            DiagLog.warning("background", "pianificazione refresh non riuscita: \(DiagLog.describe(error))")
        }

        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 60 * 60)
        do { try BGTaskScheduler.shared.submit(processing) } catch {
            DiagLog.warning("background", "pianificazione processing non riuscita: \(DiagLog.describe(error))")
        }
    }
}

/// BGTask non è Sendable: lo custodiamo e chiamiamo setTaskCompleted una sola volta.
final class TaskBox: @unchecked Sendable {
    private var task: BGTask?
    private let lock = NSLock()

    init(_ task: BGTask) { self.task = task }

    func complete(success: Bool) {
        lock.lock()
        let t = task
        task = nil
        lock.unlock()
        t?.setTaskCompleted(success: success)
    }
}
