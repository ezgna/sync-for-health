import Foundation
import HealthKit

/// Construct synthetic objects only. Never request authorization, instantiate
/// an HKHealthStore, read device health data, or contact a server.
@main
@MainActor
struct ExtendedHealthContractTests {
    struct Failure: Error { let name: String }
    static var passed = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw Failure(name: name) }
        passed += 1
        print("PASS \(name)")
    }

    static func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    static func main() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.0001)
        let gad = HKGAD7Assessment(date: date, answers: [.notAtAll, .severalDays, .moreThanHalfTheDays,
                                                        .nearlyEveryDay, .severalDays, .notAtAll, .nearlyEveryDay],
                                  metadata: ["synthetic-bool": true])
        let gadRecord = try ExtendedHealth.assessment(gad)
        try check(gadRecord.risposte_raw == [0, 1, 2, 3, 1, 0, 3], "gad_original_answer_order")
        try check(gadRecord.punteggio == gad.score && gadRecord.rischio_raw == gad.risk.rawValue,
                  "gad_apple_score_and_risk_not_recomputed")
        let gadJSON = try json(gadRecord)
        try check(gadJSON["metadati_typed"] != nil, "assessment_typed_metadata_retained")

        let phq = HKPHQ9Assessment(date: date, answers: [.nearlyEveryDay, .notAtAll, .severalDays,
                                                        .moreThanHalfTheDays, .notAtAll, .nearlyEveryDay,
                                                        .notAtAll, .severalDays, .preferNotToAnswer])
        let phqRecord = try ExtendedHealth.assessment(phq)
        try check(phqRecord.risposte_raw.last == 4 && phqRecord.risposte_raw.count == 9,
                  "phq_unanswered_ninth_response_is_not_zero")
        let erased = ExtendedSampleRecord.assessment(phqRecord)
        let erasedJSON = try json(erased)
        try check(erased.id == phq.uuid.uuidString && erased.section == "valutazioni", "assessment_transport_routing")
        try check(erasedJSON["uuid"] as? String == phq.uuid.uuidString && erasedJSON["assessment"] == nil,
                  "type_erasure_has_no_extra_enum_wrapper")

        let diopter = HKUnit.diopter()
        let degrees = HKUnit.degreeAngle()
        let millimeter = HKUnit.meterUnit(with: .milli)
        let prism = HKVisionPrism(amount: HKQuantity(unit: .prismDiopter(), doubleValue: 1.75),
                                  angle: HKQuantity(unit: degrees, doubleValue: 123.456789), eye: .right)
        let rightGlasses = HKGlassesLensSpecification(
            sphere: HKQuantity(unit: diopter, doubleValue: -2.125),
            cylinder: HKQuantity(unit: diopter, doubleValue: -0.75),
            axis: HKQuantity(unit: degrees, doubleValue: 170.123456789),
            addPower: HKQuantity(unit: diopter, doubleValue: 1.25),
            vertexDistance: HKQuantity(unit: millimeter, doubleValue: 12.345), prism: prism,
            farPupillaryDistance: HKQuantity(unit: millimeter, doubleValue: 31.5),
            nearPupillaryDistance: HKQuantity(unit: millimeter, doubleValue: 30.5))
        let glasses = HKGlassesPrescription(rightEyeSpecification: rightGlasses, leftEyeSpecification: nil,
                                            dateIssued: date, expirationDate: date.addingTimeInterval(1_000),
                                            device: nil, metadata: ["synthetic": "glasses"])
        let glassesRecord = ExtendedHealth.visionPrescription(glasses)
        try check(glassesRecord.sottotipo == "glasses" && glassesRecord.occhio_sinistro == nil,
                  "asymmetric_glasses_does_not_invent_missing_eye")
        try check(glassesRecord.occhio_destro?.sfera_diottrie == -2.125
                    && glassesRecord.occhio_destro?.cilindro_diottrie == -0.75
                    && glassesRecord.occhio_destro?.addizione_diottrie == 1.25,
                  "glasses_sphere_cylinder_and_multifocal_addition")
        try check(glassesRecord.occhio_destro?.asse_gradi == 170.123456789,
                  "glasses_axis_not_rounded")
        try check(glassesRecord.occhio_destro?.distanza_vertice_mm == 12.345
                    && glassesRecord.occhio_destro?.distanza_pupillare_lontano_mm == 31.5
                    && glassesRecord.occhio_destro?.distanza_pupillare_vicino_mm == 30.5,
                  "all_glasses_distances_retained")
        let recordedPrism = glassesRecord.occhio_destro!.prisma!
        try check(recordedPrism.quantita_diottrie_prismatiche == 1.75
                    && recordedPrism.angolo_gradi == 123.456789
                    && recordedPrism.occhio_raw == prism.eye.rawValue,
                  "prism_polar_fields_and_eye")
        try check(recordedPrism.quantita_verticale_diottrie_prismatiche == prism.verticalAmount.doubleValue(for: .prismDiopter())
                    && recordedPrism.quantita_orizzontale_diottrie_prismatiche == prism.horizontalAmount.doubleValue(for: .prismDiopter())
                    && recordedPrism.base_verticale_raw == prism.verticalBase.rawValue
                    && recordedPrism.base_orizzontale_raw == prism.horizontalBase.rawValue,
                  "prism_rectangular_fields_retained_too")
        try check(glassesRecord.data_emissione == ISO.string(date)
                    && glassesRecord.data_scadenza == ISO.string(date.addingTimeInterval(1_000)),
                  "prescription_issue_and_expiration_dates")

        let leftContact = HKContactsLensSpecification(sphere: HKQuantity(unit: diopter, doubleValue: 0),
                                                       cylinder: nil, axis: nil, addPower: nil,
                                                       baseCurve: HKQuantity(unit: millimeter, doubleValue: 8.6),
                                                       diameter: HKQuantity(unit: millimeter, doubleValue: 14.2))
        let contacts = HKContactsPrescription(rightEyeSpecification: nil, leftEyeSpecification: leftContact, brand: "synthetic-brand",
                                              dateIssued: date, expirationDate: nil, device: nil, metadata: nil)
        let contactsRecord = ExtendedHealth.visionPrescription(contacts)
        try check(contactsRecord.marca == "synthetic-brand" && contactsRecord.sottotipo == "contacts",
                  "contact_brand_and_type_retained")
        try check(contactsRecord.occhio_destro == nil && contactsRecord.occhio_sinistro?.sfera_diottrie == 0,
                  "zero_lens_power_is_not_missing")
        try check(contactsRecord.occhio_sinistro?.curva_base_mm == 8.6
                    && contactsRecord.occhio_sinistro?.diametro_mm == 14.2,
                  "contact_base_curve_and_diameter")
        try check(contactsRecord.occhio_sinistro?.cilindro_diottrie == nil && contactsRecord.data_scadenza == nil,
                  "optional_prescription_fields_remain_absent")

        // HKHeartbeatSeriesSample and HKMedicationDoseEvent have no public
        // offline constructors. Verify the wire representation without a store.
        let heartbeat = HeartbeatSeriesRecord(
            uuid: "11111111-1111-4111-8111-111111111111", tipo: "HKDataTypeIdentifierHeartbeatSeries",
            inizio: ISO.string(date), fine: ISO.string(date.addingTimeInterval(1)), fonte: "synthetic",
            numero_battiti: 2,
            battiti: [HeartbeatPoint(tempo_dall_inizio_s: 0.123456789, preceduto_da_interruzione: false),
                      HeartbeatPoint(tempo_dall_inizio_s: 0.923456789, preceduto_da_interruzione: true)])
        let heartbeatJSON = try json(ExtendedSampleRecord.heartbeatSeries(heartbeat))
        let beats = heartbeatJSON["battiti"] as! [[String: Any]]
        try check(beats.count == 2 && beats[0]["tempo_dall_inizio_s"] as? Double == 0.123456789,
                  "heartbeat_original_offsets_retained")
        try check(beats[1]["preceduto_da_interruzione"] as? Bool == true,
                  "heartbeat_gap_flag_retained")

        let summary = HKActivitySummary()
        summary.activeEnergyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: 123.456789)
        summary.activeEnergyBurnedGoal = HKQuantity(unit: .kilocalorie(), doubleValue: 450)
        summary.appleMoveTime = HKQuantity(unit: .minute(), doubleValue: 10.5)
        summary.appleMoveTimeGoal = HKQuantity(unit: .minute(), doubleValue: 30)
        summary.appleExerciseTime = HKQuantity(unit: .minute(), doubleValue: 20.25)
        summary.exerciseTimeGoal = HKQuantity(unit: .minute(), doubleValue: 25)
        summary.appleStandHours = HKQuantity(unit: .count(), doubleValue: 5)
        summary.standHoursGoal = HKQuantity(unit: .count(), doubleValue: 10)
        summary.isPaused = true
        let day = DateComponents(era: 1, year: 2026, month: 10, day: 25)
        let dailyRecord = try ExtendedHealth.activitySummary(summary, dateComponents: day)
        try check(dailyRecord.energia_attiva_kcal == 123.456789 && dailyRecord.esercizio_s == 1_215,
                  "activity_totals_keep_precision_and_explicit_units")
        try check(dailyRecord.obiettivo_esercizio_s == 1_500 && dailyRecord.obiettivo_ore_in_piedi == 10,
                  "activity_current_goals_exported")
        try check(dailyRecord.in_pausa, "paused_activity_ring_state_exported")
        let stableDay = dailyRecord.uuid
        summary.activeEnergyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: 999)
        let editedDailyRecord = try ExtendedHealth.activitySummary(summary, dateComponents: day)
        try check(editedDailyRecord.uuid == stableDay && editedDailyRecord.energia_attiva_kcal == 999,
                  "edited_daily_summary_keeps_its_day_identity")
        try check(ExtendedHealth.summaryID(era: 1, year: 2026, month: 10, day: 25)
                    != ExtendedHealth.summaryID(era: 1, year: 2026, month: 10, day: 26),
                  "different_days_have_distinct_namespaced_uuids")
        try check(UUID(uuidString: stableDay) != nil, "daily_identity_is_valid_uuid")
        let snapshot = ActivitySummarySnapshot(snapshot_id: UUID().uuidString,
                                                rilevato: ISO.string(date), fuso_orario: "Asia/Tokyo", riepiloghi: [])
        let snapshotJSON = try json(snapshot)
        try check((snapshotJSON["riepiloghi"] as? [Any])?.isEmpty == true
                    && snapshotJSON["completo"] as? Bool == true,
                  "empty_successful_snapshot_is_explicit")
        try check(snapshotJSON["ambito"] as? String == "currently_authorized_activity_summaries",
                  "snapshot_scope_does_not_claim_all_permissions")
        print("\(passed) extended serialization tests passed")
    }
}
