import Foundation

/// Il documento JSON inviato all'endpoint. Vedi docs/PROTOCOL.md.
/// Le sezioni vuote sono omesse (nil).
struct Payload: Encodable, Sendable {
    var app = "salute-libera"
    var versione = 1
    var dispositivo: String
    var inviato: String
    var campioni: [QuantityRecord]?
    var categorie: [CategoryRecord]?
    var allenamenti: [WorkoutRecord]?
    var ecg: [ECGRecord]?
    var audiogrammi: [AudiogramRecord]?
    var stati_d_animo: [StateOfMindRecord]?
    var eliminati: [String]?
    var caratteristiche: Characteristics?
}

/// Payload della "Prova connessione": {"app":"salute-libera","versione":1,"prova":true}
struct TestPayload: Encodable, Sendable {
    var app = "salute-libera"
    var versione = 1
    var prova = true
}

struct QuantityRecord: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let valore: Double
    let unita: String
    let inizio: String
    let fine: String
    let fonte: String
    var metadati: [String: String]?
}

struct CategoryRecord: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let valore: Int
    var etichetta: String?
    let inizio: String
    let fine: String
    let fonte: String
    var metadati: [String: String]?
}

struct WorkoutStat: Encodable, Sendable {
    let unita: String
    var somma: Double?
    var media: Double?
    var minimo: Double?
    var massimo: Double?
}

struct RoutePoint: Encodable, Sendable {
    let lat: Double
    let lon: Double
    let alt: Double
    let t: String
}

struct WorkoutRecord: Encodable, Sendable {
    let uuid: String
    let attivita: String
    let inizio: String
    let fine: String
    let durata_s: Double
    var energia_kcal: Double?
    var distanza_m: Double?
    let fonte: String
    var statistiche: [String: WorkoutStat]?
    var metadati: [String: String]?
    var percorso: [RoutePoint]?
}

struct ECGRecord: Encodable, Sendable {
    let uuid: String
    let inizio: String
    var fine: String?
    let classificazione: String
    var bpm_medio: Double?
    var sintomi: String?
    var fonte: String?
    /// Frequenza di campionamento del tracciato (Hz), di solito 512.
    var frequenza_hz: Double?
    /// Sempre "µV" quando il tracciato è presente.
    var unita_tracciato: String?
    /// Derivazione simile a DI (appleWatchSimilarToLeadI), in microvolt, 1 decimale.
    var tracciato: [Double]?
}

struct AudiogramPoint: Encodable, Sendable {
    let frequenza_hz: Double
    var sinistro_dbhl: Double?
    var destro_dbhl: Double?
}

struct AudiogramRecord: Encodable, Sendable {
    let uuid: String
    let inizio: String
    let fine: String
    let fonte: String
    let punti: [AudiogramPoint]
}

struct StateOfMindRecord: Encodable, Sendable {
    let uuid: String
    let inizio: String
    let tipo: String
    let valenza: Double
    let classificazione: String
    let etichette: [String]
    let associazioni: [String]
    let fonte: String
}

struct Characteristics: Encodable, Sendable {
    var data_di_nascita: String?
    var sesso: String?
    var gruppo_sanguigno: String?
    var fototipo: String?
    var sedia_a_rotelle: Bool?
    var modalita_movimento: String?

    var isEmpty: Bool {
        data_di_nascita == nil && sesso == nil && gruppo_sanguigno == nil
            && fototipo == nil && sedia_a_rotelle == nil && modalita_movimento == nil
    }
}

/// Date in ISO 8601 con fuso orario locale, es. 2026-10-01T08:15:00+02:00.
enum ISO {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
    private static let lock = NSLock()

    static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
