import BackgroundTasks
import Foundation
import HealthKit

/// Consegna in background di HealthKit: un'unica HKObserverQuery su tutti i tipi attivi
/// e enableBackgroundDelivery per ciascuno. Il completion handler viene SEMPRE chiamato.
@MainActor
enum HealthBackground {
    private static var query: HKObserverQuery?

    static func start(groups: Set<DataGroup>) {
        guard Health.isAvailable else { return }
        if AppEnvironment.isDemo { return }
        stop()
        let entries = HealthCatalog.entries(in: groups)
        let descriptors = entries.compactMap { entry in
            entry.sampleType.map { HKQueryDescriptor(sampleType: $0, predicate: nil) }
        }
        guard !descriptors.isEmpty else { return }

        let q = HKObserverQuery(queryDescriptors: descriptors) { _, types, completion, error in
            let done = CompletionBox(completion)
            if let error {
                DiagLog.error("osservatore", "errore: \(DiagLog.describe(error))")
                done.call()
                return
            }
            let names = (types ?? []).map(\.identifier).sorted()
            DiagLog.info("osservatore", "nuovi dati segnalati per \(names.count) tipi\(names.isEmpty ? "" : ": " + names.prefix(8).joined(separator: ", "))\(names.count > 8 ? ", …" : "")")
            Task {
                await SyncCoordinator.shared.request(.automatico)
                done.call()
            }
        }
        query = q
        Health.store.execute(q)
        DiagLog.info("osservatore", "avviato su \(descriptors.count) tipi")

        for entry in entries {
            guard let type = entry.sampleType else { continue }
            Health.store.enableBackgroundDelivery(for: type, frequency: entry.immediate ? .immediate : .hourly) { _, error in
                if let error {
                    DiagLog.warning("background", "consegna in background non attiva per \(type.identifier): \(DiagLog.describe(error))")
                }
            }
        }
    }

    static func stop() {
        if let query { Health.store.stop(query) }
        query = nil
    }

    /// Riallinea osservatori e consegna in background ai gruppi attivi.
    static func restart(groups: Set<DataGroup>) {
        Health.store.disableAllBackgroundDelivery { _, _ in }
        start(groups: groups)
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
    static let refreshID = "it.vcnngr.syncforhealth.refresh"
    static let processingID = "it.vcnngr.syncforhealth.processing"

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
            await SyncCoordinator.shared.request(trigger)
            box.complete(success: !Task.isCancelled)
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
