import Foundation

/// Il documento JSON inviato all'endpoint. Vedi docs/PROTOCOL.md.
/// Le sezioni vuote sono omesse (nil).
struct Payload: Encodable, Sendable {
    var app = "salute-libera"
    var versione = 2
    var dispositivo: String
    var inviato: String
    var campioni: [QuantityRecord]?
    var categorie: [CategoryRecord]?
    var allenamenti: [WorkoutRecord]?
    var ecg: [ECGRecord]?
    var audiogrammi: [AudiogramRecord]?
    var stati_d_animo: [StateOfMindRecord]?
    var correlazioni: [CorrelationRecord]?
    var eliminati: [String]?
    var caratteristiche: Characteristics?
    /// Identità del documento: non cambia durante i tentativi dello stesso upload.
    var batch_id = UUID().uuidString
    /// Obbligatori nel trasporto v2. I default nil mantengono compatibili i costruttori demo.
    var installation_id: String?
    var destination_id: String?
    var checkpoint: SyncCheckpoint?
}

/// La prova usa lo stesso contratto di conferma v2 dei documenti sanitari.
struct TestPayload: Encodable, Sendable {
    var app = "salute-libera"
    var versione = 2
    var prova = true
    var batch_id = UUID().uuidString
    var installation_id: String?
    var destination_id: String?
}

/// Conferma che la scansione dei gruppi richiesti è terminata, non che HealthKit
/// abbia concesso ogni permesso di lettura (Apple non rivela i permessi negati).
struct SyncCheckpoint: Encodable, Sendable {
    var status = "scan_complete"
    let scan_id: String
    let completed_at: String
    let groups: [String]
    let routes: Bool
    /// Only explicit HealthKit authorization errors are listed. An empty result
    /// cannot identify denied read access and is never labelled as pending.
    var pending_types: [String]?
}

/// Dati originali della sorgente e del dispositivo, separati dal nome visualizzato.
struct SampleProvenance: Encodable, Sendable {
    let bundle_id: String
    var source_version: String?
    var source_product_type: String?
    var source_os_version: String?
    var device: DeviceProvenance?
}

struct DeviceProvenance: Encodable, Sendable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var hardware_version: String?
    var firmware_version: String?
    var software_version: String?
    var local_identifier: String?
    var udi_device_identifier: String?
}

struct QuantitySeriesPoint: Encodable, Sendable {
    let valore: Double
    let inizio: String
    let fine: String
}

/// JSON ricorsivo senza Any: i metadati conservano tipo e struttura. I valori
/// speciali (date, quantità, numeri non finiti) usano un oggetto con il campo type.
indirect enum MetadataValue: Encodable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([MetadataValue])
    case object([String: MetadataValue])

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .unsigned(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }
}

struct RecordInterval: Encodable, Sendable {
    let inizio: String
    let fine: String
}

struct DiscreteQuantityRecord: Encodable, Sendable {
    let unita: String
    let minimo: Double
    let media: Double
    let massimo: Double
    let ultimo: Double
    let intervallo_ultimo: RecordInterval
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
    var provenienza: SampleProvenance?
    var numero_quantita: Int?
    /// Quantità elementari quando HKQuantitySample.count > 1; stessa unità del riepilogo.
    var serie: [QuantitySeriesPoint]?
    var metadati_typed: [String: MetadataValue]?
    var statistiche_discrete: DiscreteQuantityRecord?
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
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
}

struct CorrelationMember: Encodable, Sendable {
    let uuid: String
    let tipo: String
}

/// Membri reali del contenitore HealthKit; mai ricostruiti confrontando gli orari.
/// HealthKit può nascondere membri per cui l'utente non ha concesso la lettura.
struct CorrelationRecord: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let inizio: String
    let fine: String
    let fonte: String
    let membri: [CorrelationMember]
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
}

struct WorkoutStat: Encodable, Sendable {
    let unita: String
    var somma: Double?
    var media: Double?
    var minimo: Double?
    var massimo: Double?
    var ultimo: Double?
    var intervallo_ultimo: RecordInterval?
    var durata_s: Double?
    var inizio: String?
    var fine: String?
    /// Se non esiste un'unità convertibile, questi oggetti espliciti preservano
    /// le quantità originali e un errore visibile, senza eliminare la statistica.
    var quantita_originali: [String: MetadataValue]?
    var conversione: String?
}

struct WorkoutEventRecord: Encodable, Sendable {
    let tipo_raw: Int
    let inizio: String
    let fine: String
    var metadati: [String: String]?
    var metadati_typed: [String: MetadataValue]?
}

struct WorkoutConfigurationRecord: Encodable, Sendable {
    let attivita: String
    let attivita_raw: UInt
    let luogo_raw: Int
    let luogo_nuoto_raw: Int
    var lunghezza_vasca_m: Double?
}

struct WorkoutActivityRecord: Encodable, Sendable {
    let uuid: String
    let configurazione: WorkoutConfigurationRecord
    let inizio: String
    var fine: String?
    let durata_s: Double
    let eventi: [WorkoutEventRecord]
    let statistiche: [String: WorkoutStat]
    var metadati: [String: String]?
    var metadati_typed: [String: MetadataValue]?
}

struct WorkoutRouteRecord: Encodable, Sendable {
    let uuid: String
    let inizio: String
    let fine: String
    let fonte: String
    let punti: [RoutePoint]
    var provenienza: SampleProvenance?
    var metadati: [String: String]?
    var metadati_typed: [String: MetadataValue]?
}

struct WorkoutSampleReference: Encodable, Sendable {
    let uuid: String
    let tipo: String
}

struct WorkoutEffortRelationshipRecord: Encodable, Sendable {
    let workout_uuid: String
    var attivita_uuid: String?
    /// nil e [] mantengono il significato distinto dell'API originale.
    var campioni: [WorkoutSampleReference]?
}

struct RoutePoint: Encodable, Sendable {
    let lat: Double
    let lon: Double
    let alt: Double
    let t: String
    var precisione_orizzontale_m: Double?
    var precisione_verticale_m: Double?
    var velocita_m_s: Double?
    var precisione_velocita_m_s: Double?
    var direzione_gradi: Double?
    var precisione_direzione_gradi: Double?
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
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
    var attivita_raw: UInt?
    var eventi: [WorkoutEventRecord]?
    var attivita_dettaglio: [WorkoutActivityRecord]?
    /// nil = non richiesti; [] = richiesta completata senza percorsi leggibili.
    /// I punti non vengono duplicati nel vecchio campo percorso.
    var percorsi: [WorkoutRouteRecord]?
    var campioni_associati: [WorkoutSampleReference]?
    var ambito_campioni_associati: [String]?
    var relazioni_sforzo: [WorkoutEffortRelationshipRecord]?
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
    /// Derivazione simile a DI (appleWatchSimilarToLeadI), in microvolt, senza arrotondamenti.
    var tracciato: [Double]?
    /// Offset originali HealthKit; allineati uno a uno con tracciato.
    var tempi_tracciato_s: [Double]?
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var numero_misure: Int?
    var metadati_typed: [String: MetadataValue]?
}

struct AudiogramTest: Encodable, Sendable {
    let tipo_raw: Int
    let lato_raw: Int
    let masked: Bool
    let sensibilita_dbhl: Double
    var limite_inferiore_dbhl: Double?
    var limite_superiore_dbhl: Double?
}

struct AudiogramPoint: Encodable, Sendable {
    let frequenza_hz: Double
    var sinistro_dbhl: Double?
    var destro_dbhl: Double?
    /// Tutti i test, inclusi masking e clamping; i campi sinistro/destro sono riepiloghi.
    var test: [AudiogramTest]?
}

struct AudiogramRecord: Encodable, Sendable {
    let uuid: String
    let inizio: String
    let fine: String
    let fonte: String
    let punti: [AudiogramPoint]
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
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
    var fine: String?
    var tipo_raw: Int?
    var classificazione_raw: Int?
    var etichette_raw: [Int]?
    var associazioni_raw: [Int]?
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
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

/// Date in ISO 8601 UTC, con frazioni di secondo. L'eventuale HKMetadataKeyTimeZone
/// originale rimane nei metadati: il fuso del telefono durante l'upload non lo sostituisce.
enum ISO {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    private static let lock = NSLock()

    static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        // ISO8601DateFormatter con withFractionalSeconds produce solo millisecondi.
        // Calcoliamo la frazione dal riferimento nativo di Date (2001), evitando
        // l'ulteriore perdita di precisione del passaggio per l'epoch 1970.
        let reference = date.timeIntervalSinceReferenceDate
        var whole = floor(reference)
        var nanos = Int(((reference - whole) * 1_000_000_000).rounded())
        if nanos == 1_000_000_000 {
            whole += 1
            nanos = 0
        }
        let base = formatter.string(from: Date(timeIntervalSinceReferenceDate: whole))
        // Il formatter è UTC con una frazione .000Z perché whole è intero.
        return String(base.dropLast(5)) + String(format: ".%09dZ", nanos)
    }
}
