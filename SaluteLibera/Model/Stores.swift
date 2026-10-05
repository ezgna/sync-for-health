import Foundation
import HealthKit
import Observation

/// Cartella Application Support/SaluteLibera — qui stanno solo ancore, registro e stato.
/// Esclusa dai backup iCloud: nulla di ciò che l'app scrive finisce su iCloud.
enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("SaluteLibera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        excludeFromBackup(&dir)
        // I file restano leggibili in background dopo il primo sblocco.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        return dir
    }()

    static func excludeFromBackup(_ url: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Ancore HKAnchoredObjectQuery per tipo, archiviate con NSKeyedArchiver.
/// Un'ancora viene salvata solo DOPO che il server ha risposto 2xx.
final class AnchorStore: @unchecked Sendable {
    static let shared = AnchorStore()

    private let url = Storage.directory.appendingPathComponent("ancore.plist")
    private let lock = NSLock()
    private var cache: [String: Data]

    private init() {
        if let data = try? Data(contentsOf: url),
           let dict = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            cache = dict
        } else {
            cache = [:]
        }
    }

    func anchor(for identifier: String) -> HKQueryAnchor? {
        lock.lock(); defer { lock.unlock() }
        guard let data = cache[identifier] else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    static func archive(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    /// Salva in blocco le ancore di un invio riuscito.
    func commit(_ anchors: [String: Data]) {
        guard !anchors.isEmpty else { return }
        lock.lock()
        cache.merge(anchors) { _, new in new }
        let snapshot = cache
        lock.unlock()
        persist(snapshot)
    }

    /// Dimentica l'ancora di un solo tipo (che verrà reinviato dall'inizio).
    func remove(_ identifier: String) {
        lock.lock()
        let existed = cache.removeValue(forKey: identifier) != nil
        let snapshot = cache
        lock.unlock()
        if existed { persist(snapshot) }
    }

    /// Dimentica tutte le ancore: il prossimo invio ripartirà dall'intero storico.
    func reset() {
        lock.lock()
        cache = [:]
        lock.unlock()
        persist([:])
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return cache.isEmpty
    }

    private func persist(_ dict: [String: Data]) {
        do {
            let data = try PropertyListEncoder().encode(dict)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            DiagLog.error("sync", "impossibile salvare le ancore: \(DiagLog.describe(error))")
        }
    }
}

/// Una voce del registro invii.
struct SyncRecord: Codable, Identifiable, Sendable, Hashable {
    enum Outcome: String, Codable, Sendable {
        case riuscito, errore, nienteDaInviare, interrotto
        /// Ha consegnato alcuni blocchi, poi si è fermato (es. iPhone bloccato): riprende da solo.
        case parziale
        /// Non ha potuto leggere Salute perché l'iPhone è bloccato. Non è un errore.
        case inAttesa
    }
    enum Trigger: String, Codable, Sendable { case manuale, automatico, background, prova, storico }

    var id = UUID()
    var date: Date
    var samples: Int
    var deleted: Int
    var outcome: Outcome
    var trigger: Trigger
    var message: String?
    var duration: TimeInterval
    var bytes: Int
    var requests: Int
}

extension SyncRecord {
    /// Ha consegnato al server almeno un blocco (riuscito o parziale).
    var delivered: Bool {
        outcome == .riuscito || (samples + deleted > 0 && outcome != .nienteDaInviare)
    }
}

/// Avanzamento di un invio in corso (per la schermata Oggi).
struct SyncProgress: Sendable, Equatable {
    var typeIndex = 0
    var typeCount = 0
    var typeIdentifier: String?
    var samplesSent = 0
    var blocksSent = 0

    /// "StepCount" → "Step Count"
    var typeName: String? {
        guard let id = typeIdentifier else { return nil }
        let short = id.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKDataTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "Workout")
        var out = ""
        for ch in short {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

/// Registro degli ultimi 50 invii.
@MainActor
@Observable
final class SyncLog {
    static let shared = SyncLog()
    nonisolated static let limit = 50

    private(set) var records: [SyncRecord] = []
    private let url = Storage.directory.appendingPathComponent("registro.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([SyncRecord].self, from: data) {
            records = list
        }
    }

    func add(_ record: SyncRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        save()
    }

    /// Sostituisce il registro (usato solo dalla modalità dimostrativa, senza salvare).
    func replaceForDemo(_ list: [SyncRecord]) { records = list }

    /// Ricarica il registro vero (all'uscita dalla modalità dimostrativa).
    func reloadFromDisk() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([SyncRecord].self, from: data) {
            records = list
        } else {
            records = []
        }
    }

    /// Ultimo invio che ha consegnato dati (o confermato di essere in pari).
    var lastSuccess: SyncRecord? {
        records.first { $0.delivered || $0.outcome == .nienteDaInviare }
    }

    var samplesToday: Int {
        let cal = Calendar.current
        return records.filter { cal.isDateInToday($0.date) && $0.delivered }
            .reduce(0) { $0 + $1.samples + $1.deleted }
    }

    private func save() {
        if AppEnvironment.isDemo { return }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
