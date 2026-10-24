import CryptoKit
import Foundation
import HealthKit

/// HealthKit records which are neither ordinary quantities nor categories.
/// Every query below is read-only. A successful query describes what HealthKit
/// currently exposes to this app; it does not prove that all read access was granted.
enum ExtendedHealth {
    enum Failure: Error {
        case incompleteHeartbeatSeries(expected: Int, actual: Int)
        case unsupportedAssessment(String)
        case invalidAssessmentAnswerCount(expected: Int, actual: Int)
        case invalidSummaryDate
        case unsupportedSample(String)
    }

    static func heartbeatSeries(_ sample: HKHeartbeatSeriesSample,
                                store: HKHealthStore) async throws -> HeartbeatSeriesRecord {
        try Task.checkCancellation()
        var points: [HeartbeatPoint] = []
        points.reserveCapacity(sample.count)
        for try await beat in HKHeartbeatSeriesQueryDescriptor(sample).results(for: store) {
            try Task.checkCancellation()
            points.append(HeartbeatPoint(
                tempo_dall_inizio_s: beat.timeIntervalSinceStart,
                preceduto_da_interruzione: beat.precededByGap,
                tempo_derivato: ISO.string(sample.startDate.addingTimeInterval(beat.timeIntervalSinceStart))))
        }
        try Task.checkCancellation()
        guard points.count == sample.count else {
            throw Failure.incompleteHeartbeatSeries(expected: sample.count, actual: points.count)
        }
        return HeartbeatSeriesRecord(
            uuid: sample.uuid.uuidString, tipo: sample.sampleType.identifier,
            inizio: ISO.string(sample.startDate), fine: ISO.string(sample.endDate),
            fonte: Serializer.source(sample), numero_battiti: sample.count, battiti: points,
            metadati: Serializer.metadata(sample.metadata), provenienza: Serializer.provenance(sample),
            metadati_typed: Serializer.typedMetadata(sample.metadata))
    }

    static func sample(_ sample: HKSample, store: HKHealthStore) async throws -> ExtendedSampleRecord {
        try Task.checkCancellation()
        if let heartbeat = sample as? HKHeartbeatSeriesSample {
            return .heartbeatSeries(try await heartbeatSeries(heartbeat, store: store))
        }
        if let scored = sample as? HKScoredAssessment {
            return .assessment(try assessment(scored))
        }
        if let vision = sample as? HKVisionPrescription {
            return .visionPrescription(visionPrescription(vision))
        }
        if let medication = sample as? HKMedicationDoseEvent {
            return .medicationDose(try medicationDose(medication))
        }
        throw Failure.unsupportedSample(sample.sampleType.identifier)
    }

    /// Keep the original questionnaire responses and Apple's classification.
    /// In particular, PHQ-9's unanswered ninth question remains raw value 4.
    static func assessment(_ sample: HKScoredAssessment) throws -> AssessmentRecord {
        let risk: Int
        let answers: [Int]
        let expected: Int
        if let gad = sample as? HKGAD7Assessment {
            risk = gad.risk.rawValue
            answers = gad.answers.map(\.rawValue)
            expected = 7
        } else if let phq = sample as? HKPHQ9Assessment {
            risk = phq.risk.rawValue
            answers = phq.answers.map(\.rawValue)
            expected = 9
        } else {
            throw Failure.unsupportedAssessment(sample.sampleType.identifier)
        }
        guard answers.count == expected else {
            throw Failure.invalidAssessmentAnswerCount(expected: expected, actual: answers.count)
        }
        return AssessmentRecord(
            uuid: sample.uuid.uuidString, tipo: sample.sampleType.identifier,
            inizio: ISO.string(sample.startDate), fine: ISO.string(sample.endDate),
            fonte: Serializer.source(sample), punteggio: sample.score,
            rischio_raw: risk, risposte_raw: answers,
            metadati: Serializer.metadata(sample.metadata), provenienza: Serializer.provenance(sample),
            metadati_typed: Serializer.typedMetadata(sample.metadata))
    }

    static func visionPrescription(_ sample: HKVisionPrescription) -> VisionPrescriptionRecord {
        var record = VisionPrescriptionRecord(
            uuid: sample.uuid.uuidString, tipo: sample.sampleType.identifier,
            inizio: ISO.string(sample.startDate), fine: ISO.string(sample.endDate),
            fonte: Serializer.source(sample), tipo_prescrizione_raw: sample.prescriptionType.rawValue,
            data_emissione: ISO.string(sample.dateIssued),
            data_scadenza: sample.expirationDate.map(ISO.string),
            metadati: Serializer.metadata(sample.metadata), provenienza: Serializer.provenance(sample),
            metadati_typed: Serializer.typedMetadata(sample.metadata))
        if let glasses = sample as? HKGlassesPrescription {
            record.sottotipo = "glasses"
            record.occhio_destro = glasses.rightEye.map(glassesLens)
            record.occhio_sinistro = glasses.leftEye.map(glassesLens)
        } else if let contacts = sample as? HKContactsPrescription {
            record.sottotipo = "contacts"
            record.marca = contacts.brand
            record.occhio_destro = contacts.rightEye.map(contactsLens)
            record.occhio_sinistro = contacts.leftEye.map(contactsLens)
        }
        return record
    }

    private static func lens(_ specification: HKLensSpecification) -> VisionLensRecord {
        VisionLensRecord(
            sfera_diottrie: specification.sphere.doubleValue(for: .diopter()),
            cilindro_diottrie: specification.cylinder?.doubleValue(for: .diopter()),
            asse_gradi: specification.axis?.doubleValue(for: .degreeAngle()),
            addizione_diottrie: specification.addPower?.doubleValue(for: .diopter()))
    }

    private static func glassesLens(_ specification: HKGlassesLensSpecification) -> VisionLensRecord {
        var record = lens(specification)
        let millimeter = HKUnit.meterUnit(with: .milli)
        record.distanza_vertice_mm = specification.vertexDistance?.doubleValue(for: millimeter)
        record.distanza_pupillare_lontano_mm = specification.farPupillaryDistance?.doubleValue(for: millimeter)
        record.distanza_pupillare_vicino_mm = specification.nearPupillaryDistance?.doubleValue(for: millimeter)
        record.prisma = specification.prism.map { prism in
            VisionPrismRecord(
                quantita_diottrie_prismatiche: prism.amount.doubleValue(for: .prismDiopter()),
                angolo_gradi: prism.angle.doubleValue(for: .degreeAngle()),
                quantita_verticale_diottrie_prismatiche: prism.verticalAmount.doubleValue(for: .prismDiopter()),
                quantita_orizzontale_diottrie_prismatiche: prism.horizontalAmount.doubleValue(for: .prismDiopter()),
                base_verticale_raw: prism.verticalBase.rawValue,
                base_orizzontale_raw: prism.horizontalBase.rawValue,
                occhio_raw: prism.eye.rawValue)
        }
        return record
    }

    private static func contactsLens(_ specification: HKContactsLensSpecification) -> VisionLensRecord {
        var record = lens(specification)
        let millimeter = HKUnit.meterUnit(with: .milli)
        record.curva_base_mm = specification.baseCurve?.doubleValue(for: millimeter)
        record.diametro_mm = specification.diameter?.doubleValue(for: millimeter)
        return record
    }

    static func medicationDose(_ sample: HKMedicationDoseEvent) throws -> MedicationDoseRecord {
        MedicationDoseRecord(
            uuid: sample.uuid.uuidString, tipo: sample.sampleType.identifier,
            inizio: ISO.string(sample.startDate), fine: ISO.string(sample.endDate),
            fonte: Serializer.source(sample),
            identificatore_farmaco: try conceptIdentifier(sample.medicationConceptIdentifier),
            tipo_programmazione_raw: sample.scheduleType.rawValue,
            data_programmata: sample.scheduledDate.map(ISO.string),
            dose_programmata: sample.scheduledDoseQuantity, dose: sample.doseQuantity,
            stato_registrazione_raw: sample.logStatus.rawValue, unita: sample.unit.unitString,
            metadati: Serializer.metadata(sample.metadata), provenienza: Serializer.provenance(sample),
            metadati_typed: Serializer.typedMetadata(sample.metadata))
    }

    /// This presents Apple's individual medication picker. Closing the picker
    /// successfully does NOT imply that every medication was selected.
    @MainActor
    static func requestMedicationSelection(store: HKHealthStore) async throws {
        try await store.requestPerObjectReadAuthorization(
            for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
    }

    /// Vision prescriptions also use per-object authorization. The ordinary
    /// authorization sheet alone must not be treated as access to every pair.
    @MainActor
    static func requestVisionPrescriptionSelection(store: HKHealthStore) async throws {
        try await store.requestPerObjectReadAuthorization(
            for: HKObjectType.visionPrescriptionType(), predicate: nil)
    }

    /// A complete query of the currently visible medication catalog, including
    /// archived entries. No artificial limit and no synthetic HKSample UUIDs.
    static func medicationSnapshot(store: HKHealthStore) async throws -> MedicationSnapshot {
        let records = try await medications(store: store)
        return MedicationSnapshot(snapshot_id: UUID().uuidString, rilevato: ISO.string(.now),
                                  farmaci: records)
    }

    static func medications(store: HKHealthStore) async throws -> [UserAnnotatedMedicationRecord] {
        try Task.checkCancellation()
        let medications = try await HKUserAnnotatedMedicationQueryDescriptor(
            predicate: nil, limit: nil).result(for: store)
        var records: [UserAnnotatedMedicationRecord] = []
        for medication in medications {
            try Task.checkCancellation()
            records.append(try userAnnotatedMedication(medication))
        }
        // The catalog query has no ordering contract. Stable ordering avoids
        // reporting a changed snapshot merely because HealthKit reordered rows.
        records.sort {
            ($0.identificatore.dominio, $0.identificatore.archivio_sha256, $0.nome)
                < ($1.identificatore.dominio, $1.identificatore.archivio_sha256, $1.nome)
        }
        try Task.checkCancellation()
        return records
    }

    static func userAnnotatedMedication(_ medication: HKUserAnnotatedMedication) throws -> UserAnnotatedMedicationRecord {
        let concept = medication.medication
        let codings = concept.relatedCodings.map {
            MedicationCodingRecord(sistema: $0.system, versione: $0.version, codice: $0.code)
        }.sorted { ($0.sistema, $0.versione ?? "", $0.codice) < ($1.sistema, $1.versione ?? "", $1.codice) }
        return UserAnnotatedMedicationRecord(
            identificatore: try conceptIdentifier(concept.identifier),
            nome: concept.displayText, forma_generale: concept.generalForm.rawValue,
            codifiche: codings, soprannome: medication.nickname,
            archiviato: medication.isArchived, ha_programmazione: medication.hasSchedule)
    }

    /// HealthKit exposes no public raw string for this identifier. Preserve its
    /// reversible NSSecureCoding form instead of using NSObject.description as an ID.
    /// The digest identifies this archive, not a promised cross-OS identifier.
    static func conceptIdentifier(_ identifier: HKHealthConceptIdentifier) throws -> HealthConceptIdentifierRecord {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true)
        return HealthConceptIdentifierRecord(
            dominio: identifier.domain.rawValue, archivio_base64: archived.base64EncodedString(),
            archivio_sha256: SHA256.hash(data: archived).map { String(format: "%02x", $0) }.joined())
    }

    /// Fetch ALL daily summaries currently visible to this app. Summaries have
    /// no HKQueryAnchor and are mutable, so they must be versioned snapshots;
    /// repeatedly sending an old prefix would miss later days and edits.
    static func activitySnapshot(store: HKHealthStore,
                                 timeZone: TimeZone = .current) async throws -> ActivitySummarySnapshot {
        let records = try await activitySummaries(store: store, timeZone: timeZone)
        return ActivitySummarySnapshot(snapshot_id: UUID().uuidString, rilevato: ISO.string(.now),
                                       fuso_orario: timeZone.identifier, riepiloghi: records)
    }

    static func activitySummaries(store: HKHealthStore,
                                  timeZone: TimeZone = .current) async throws -> [ActivitySummaryRecord] {
        try Task.checkCancellation()
        let summaries = try await HKActivitySummaryQueryDescriptor(predicate: nil).result(for: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var records: [ActivitySummaryRecord] = []
        for summary in summaries {
            try Task.checkCancellation()
            records.append(try activitySummary(summary, calendar: calendar))
        }
        records.sort { ($0.era, $0.anno, $0.mese, $0.giorno) < ($1.era, $1.anno, $1.mese, $1.giorno) }
        try Task.checkCancellation()
        return records
    }

    static func activitySummary(_ summary: HKActivitySummary,
                                calendar: Calendar) throws -> ActivitySummaryRecord {
        guard calendar.identifier == .gregorian else { throw Failure.invalidSummaryDate }
        return try activitySummary(summary, dateComponents: summary.dateComponents(for: calendar))
    }

    /// The query path supplies HealthKit's date components. Keeping this pure
    /// conversion separate also permits offline synthetic summary fixtures.
    static func activitySummary(_ summary: HKActivitySummary,
                                dateComponents components: DateComponents) throws -> ActivitySummaryRecord {
        guard let era = components.era, let year = components.year,
              let month = components.month, let day = components.day else {
            throw Failure.invalidSummaryDate
        }
        return ActivitySummaryRecord(
            uuid: summaryID(era: era, year: year, month: month, day: day),
            era: era, anno: year, mese: month, giorno: day,
            modalita_movimento_raw: summary.activityMoveMode.rawValue, in_pausa: summary.isPaused,
            energia_attiva_kcal: summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
            obiettivo_energia_attiva_kcal: summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
            movimento_s: summary.appleMoveTime.doubleValue(for: .second()),
            obiettivo_movimento_s: summary.appleMoveTimeGoal.doubleValue(for: .second()),
            esercizio_s: summary.appleExerciseTime.doubleValue(for: .second()),
            obiettivo_esercizio_s: summary.exerciseTimeGoal?.doubleValue(for: .second()),
            ore_in_piedi: summary.appleStandHours.doubleValue(for: .count()),
            obiettivo_ore_in_piedi: summary.standHoursGoal?.doubleValue(for: .count()),
            obiettivo_esercizio_legacy_s: summary.appleExerciseTimeGoal.doubleValue(for: .second()),
            obiettivo_ore_in_piedi_legacy: summary.appleStandHoursGoal.doubleValue(for: .count()))
    }

    /// A namespaced UUIDv8 from the exact calendar day, not a HealthKit object UUID.
    /// A day keeps its identity when its goal or totals subsequently change.
    static func summaryID(era: Int, year: Int, month: Int, day: Int) -> String {
        let name = "HealthBridge.activitySummary.gregorian|\(era)|\(year)|\(month)|\(day)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}

/// Type-erased only at the transport boundary. Each case encodes the record
/// itself (no enum wrapper), retaining the existing section-array convention.
enum ExtendedSampleRecord: Encodable, Sendable {
    case heartbeatSeries(HeartbeatSeriesRecord)
    case assessment(AssessmentRecord)
    case visionPrescription(VisionPrescriptionRecord)
    case medicationDose(MedicationDoseRecord)

    var id: String {
        switch self {
        case .heartbeatSeries(let record): record.uuid
        case .assessment(let record): record.uuid
        case .visionPrescription(let record): record.uuid
        case .medicationDose(let record): record.uuid
        }
    }

    var section: String {
        switch self {
        case .heartbeatSeries: "heartbeat_series"
        case .assessment: "valutazioni"
        case .visionPrescription: "prescrizioni_vista"
        case .medicationDose: "dosi_farmaci"
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .heartbeatSeries(let record): try record.encode(to: encoder)
        case .assessment(let record): try record.encode(to: encoder)
        case .visionPrescription(let record): try record.encode(to: encoder)
        case .medicationDose(let record): try record.encode(to: encoder)
        }
    }
}

struct HeartbeatPoint: Encodable, Sendable {
    /// Authoritative HealthKit offset, retained without rounding.
    let tempo_dall_inizio_s: Double
    let preceduto_da_interruzione: Bool
    /// Convenience absolute date computed from the series start and offset.
    var tempo_derivato: String?
}

struct HeartbeatSeriesRecord: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let inizio: String
    let fine: String
    let fonte: String
    let numero_battiti: Int
    let battiti: [HeartbeatPoint]
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
}

struct AssessmentRecord: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let inizio: String
    let fine: String
    let fonte: String
    let punteggio: Int
    let rischio_raw: Int
    let risposte_raw: [Int]
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
}

struct VisionPrismRecord: Encodable, Sendable {
    let quantita_diottrie_prismatiche: Double
    let angolo_gradi: Double
    let quantita_verticale_diottrie_prismatiche: Double
    let quantita_orizzontale_diottrie_prismatiche: Double
    let base_verticale_raw: Int
    let base_orizzontale_raw: Int
    let occhio_raw: Int
}

struct VisionLensRecord: Encodable, Sendable {
    let sfera_diottrie: Double
    var cilindro_diottrie: Double?
    var asse_gradi: Double?
    var addizione_diottrie: Double?
    var distanza_vertice_mm: Double?
    var distanza_pupillare_lontano_mm: Double?
    var distanza_pupillare_vicino_mm: Double?
    var prisma: VisionPrismRecord?
    var curva_base_mm: Double?
    var diametro_mm: Double?
}

struct VisionPrescriptionRecord: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let inizio: String
    let fine: String
    let fonte: String
    let tipo_prescrizione_raw: UInt
    let data_emissione: String
    var data_scadenza: String?
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
    var sottotipo = "base"
    var marca: String?
    var occhio_destro: VisionLensRecord?
    var occhio_sinistro: VisionLensRecord?
}

struct HealthConceptIdentifierRecord: Encodable, Sendable {
    let dominio: String
    let archivio_base64: String
    let archivio_sha256: String
}

struct MedicationDoseRecord: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let inizio: String
    let fine: String
    let fonte: String
    let identificatore_farmaco: HealthConceptIdentifierRecord
    let tipo_programmazione_raw: Int
    var data_programmata: String?
    var dose_programmata: Double?
    var dose: Double?
    let stato_registrazione_raw: Int
    let unita: String
    var metadati: [String: String]?
    var provenienza: SampleProvenance?
    var metadati_typed: [String: MetadataValue]?
}

struct MedicationCodingRecord: Encodable, Sendable {
    let sistema: String
    var versione: String?
    let codice: String
}

/// HKUserAnnotatedMedication is not an HKObject/HKSample. It has no sample UUID,
/// start/end dates, device, source revision, metadata, or query anchor.
struct UserAnnotatedMedicationRecord: Encodable, Sendable {
    let identificatore: HealthConceptIdentifierRecord
    let nome: String
    let forma_generale: String
    let codifiche: [MedicationCodingRecord]
    var soprannome: String?
    let archiviato: Bool
    let ha_programmazione: Bool
}

/// Keep the complete version for the destination before replacing its current
/// view. An empty successful version is meaningful. Never merge only a prefix.
/// "complete" refers to query completion, not all user permissions.
struct MedicationSnapshot: Encodable, Sendable {
    let snapshot_id: String
    let rilevato: String
    var ambito = "currently_authorized_medications"
    var completo = true
    let farmaci: [UserAnnotatedMedicationRecord]
}

struct ActivitySummaryRecord: Encodable, Sendable {
    let uuid: String
    let era: Int
    let anno: Int
    let mese: Int
    let giorno: Int
    let modalita_movimento_raw: Int
    let in_pausa: Bool
    let energia_attiva_kcal: Double
    let obiettivo_energia_attiva_kcal: Double
    let movimento_s: Double
    let obiettivo_movimento_s: Double
    let esercizio_s: Double
    var obiettivo_esercizio_s: Double?
    let ore_in_piedi: Double
    var obiettivo_ore_in_piedi: Double?
    let obiettivo_esercizio_legacy_s: Double
    let obiettivo_ore_in_piedi_legacy: Double
}

struct ActivitySummarySnapshot: Encodable, Sendable {
    let snapshot_id: String
    let rilevato: String
    var ambito = "currently_authorized_activity_summaries"
    var completo = true
    var calendario = "gregorian"
    let fuso_orario: String
    let riepiloghi: [ActivitySummaryRecord]
}
