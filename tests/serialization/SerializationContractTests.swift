import Foundation
import HealthKit

/// Offline tests: construct synthetic HealthKit objects only. No HKHealthStore,
/// authorization, user data, network, signing, or device access.
@main
struct SerializationContractTests {
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
        let t = Date(timeIntervalSinceReferenceDate: 0.0001)
        try check(ISO.string(t) == "2001-01-01T00:00:00.000100000Z", "submillisecond_utc_time")
        try check(ISO.string(t) != ISO.string(t.addingTimeInterval(0.0001)), "submillisecond_dates_remain_distinct")
        try check(ISO.string(Date(timeIntervalSinceReferenceDate: -1.25)) == "2000-12-31T23:59:58.750000000Z", "negative_reference_time")
        try check(ISO.string(Date(timeIntervalSince1970: -0.25)) == "1969-12-31T23:59:59.750000000Z", "pre_epoch_time")
        let expected = ISO.string(t)
        let resultLock = NSLock()
        nonisolated(unsafe) var concurrentMatches = true
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            let matches = ISO.string(t) == expected
            resultLock.lock(); concurrentMatches = concurrentMatches && matches; resultLock.unlock()
        }
        try check(concurrentMatches, "concurrent_date_formatter")

        let installation = "11111111-1111-4111-8111-111111111111"
        let destination = "22222222-2222-4222-8222-222222222222"
        var payload = Payload(dispositivo: "synthetic-device", inviato: expected,
                              installation_id: installation, destination_id: destination)
        let firstBatch = payload.batch_id
        payload.checkpoint = SyncCheckpoint(scan_id: "33333333-3333-4333-8333-333333333333",
                                            completed_at: expected, groups: ["cuore"], routes: false)
        let envelope = try json(payload)
        try check(envelope["versione"] as? Int == 2 && UUID(uuidString: firstBatch) != nil, "v2_document_identity")
        try check(envelope["installation_id"] as? String == installation && envelope["destination_id"] as? String == destination, "destination_scoped_identity")
        try check((envelope["checkpoint"] as? [String: Any])?["status"] as? String == "scan_complete", "explicit_scan_checkpoint")
        try check(Payload(dispositivo: "synthetic", inviato: expected).batch_id != firstBatch, "new_document_has_new_identity")
        let probe = try json(TestPayload(installation_id: installation, destination_id: destination))
        try check(probe["versione"] as? Int == 2 && probe["prova"] as? Bool == true, "connection_probe_uses_v2")

        let systolic = HKQuantityType(.bloodPressureSystolic)
        let diastolic = HKQuantityType(.bloodPressureDiastolic)
        let unit = HKUnit.millimeterOfMercury()
        let device = HKDevice(name: "synthetic-device", manufacturer: "example", model: "example-model",
                              hardwareVersion: "1", firmwareVersion: "2", softwareVersion: "3",
                              localIdentifier: "synthetic-local-id", udiDeviceIdentifier: "synthetic-udi")
        let upper = HKQuantitySample(type: systolic, quantity: HKQuantity(unit: unit, doubleValue: 123.456789),
                                     start: t, end: t, device: device,
                                     metadata: [HKMetadataKeyTimeZone: "Asia/Tokyo", "synthetic-date": t])
        let lower = HKQuantitySample(type: diastolic, quantity: HKQuantity(unit: unit, doubleValue: 77.123456), start: t, end: t)
        let quantity = Serializer.quantity(upper, unit: unit)
        try check(quantity.valore == 123.456789 && quantity.numero_quantita == 1, "quantity_preserves_value_and_count")
        try check(quantity.metadati?[HKMetadataKeyTimeZone] == "Asia/Tokyo" && quantity.metadati?["synthetic-date"] == expected, "metadata_timezone_preserved")
        try check(quantity.provenienza?.device?.local_identifier == "synthetic-local-id"
                  && quantity.provenienza?.device?.udi_device_identifier == "synthetic-udi", "original_device_provenance")
        var seriesQuantity = quantity
        seriesQuantity.numero_quantita = 2
        seriesQuantity.serie = [QuantitySeriesPoint(valore: 1.123456789, inizio: expected, fine: expected),
                                QuantitySeriesPoint(valore: 2.987654321, inizio: ISO.string(t.addingTimeInterval(0.0001)), fine: ISO.string(t.addingTimeInterval(0.0001)))]
        let seriesJSON = try json(seriesQuantity)
        let points = seriesJSON["serie"] as! [[String: Any]]
        try check(points.count == 2 && points[0]["inizio"] as? String != points[1]["inizio"] as? String, "series_dates_not_collapsed")

        let bp = HKCorrelation(type: HKCorrelationType(.bloodPressure), start: t, end: t, objects: [upper, lower])
        let correlation = Serializer.correlation(bp)
        try check(Set(correlation.membri.map(\.uuid)) == Set([upper.uuid.uuidString, lower.uuid.uuidString]), "blood_pressure_uses_real_member_uuids")
        try check(correlation.membri.map(\.uuid) == correlation.membri.map(\.uuid).sorted(), "correlation_serialization_is_deterministic")
        let unrelated = HKQuantitySample(type: diastolic, quantity: HKQuantity(unit: unit, doubleValue: 80), start: t, end: t)
        try check(!correlation.membri.contains { $0.uuid == unrelated.uuid.uuidString }, "equal_timestamp_is_not_guessed_pairing")
        let readTypes = HealthCatalog.readTypes(groups: [.cuore], includeRoutes: false)
        try check(!readTypes.contains(HKCorrelationType(.bloodPressure)) && readTypes.contains(systolic) && readTypes.contains(diastolic), "correlations_use_member_permissions")
        try check(HealthCatalog.readTypes(groups: [.attivita], includeRoutes: false).contains(HKObjectType.activitySummaryType()), "local_ring_display_permission_retained")

        var workout = WorkoutRecord(uuid: UUID().uuidString, attivita: "synthetic", inizio: expected,
                                    fine: expected, durata_s: 1, fonte: "synthetic")
        let withoutRoute = try json(workout)
        workout.percorso = []
        let emptyRoute = try json(workout)
        try check(withoutRoute["percorso"] == nil && (emptyRoute["percorso"] as? [Any])?.isEmpty == true, "empty_route_is_explicit_replacement")

        let waveform = [1.123456789, -0.0123456789]
        let offsets = [0.0, 0.001953125]
        let ecg = ECGRecord(uuid: UUID().uuidString, inizio: expected, classificazione: "synthetic",
                            tracciato: waveform, tempi_tracciato_s: offsets)
        let ecgJSON = try json(ecg)
        try check(ecgJSON["tracciato"] as? [Double] == waveform && ecgJSON["tempi_tracciato_s"] as? [Double] == offsets,
                  "ecg_values_and_original_offsets_are_lossless")

        let dbhl = HKUnit.decibelHearingLevel()
        let clamp = try HKAudiogramSensitivityPointClampingRange(lowerBound: 0, upperBound: 90)
        let air = try HKAudiogramSensitivityTest(sensitivity: HKQuantity(unit: dbhl, doubleValue: 12.5), type: .air,
                                                masked: false, side: .left, clampingRange: nil)
        let masked = try HKAudiogramSensitivityTest(sensitivity: HKQuantity(unit: dbhl, doubleValue: 25.5), type: .air,
                                                   masked: true, side: .right, clampingRange: clamp)
        let audiogramPoint = try HKAudiogramSensitivityPoint(frequency: HKQuantity(unit: .hertz(), doubleValue: 1000), tests: [air, masked])
        let audiogram = HKAudiogramSample(sensitivityPoints: [audiogramPoint], start: t, end: t, device: device,
                                         metadata: [HKMetadataKeyTimeZone: "Asia/Tokyo"])
        let audio = Serializer.audiogram(audiogram)
        try check(audio.punti[0].test?.count == 2 && audio.punti[0].test?[1].masked == true
                  && audio.punti[0].test?[1].limite_superiore_dbhl == 90, "audiogram_preserves_masking_and_clamping")
        try check(audio.punti[0].sinistro_dbhl == 12.5 && audio.punti[0].destro_dbhl == nil, "masked_test_is_not_presented_as_unmasked_summary")
        try check(audio.metadati?[HKMetadataKeyTimeZone] == "Asia/Tokyo" && audio.provenienza?.device?.model == "example-model", "audiogram_metadata_and_device")

        let mind = HKStateOfMind(date: t, kind: .dailyMood, valence: 0.3, labels: [.calm, .hopeful], associations: [.health, .work],
                                 metadata: [HKMetadataKeyTimeZone: "Asia/Tokyo"])
        let state = Serializer.stateOfMind(mind)
        try check(state.tipo_raw == HKStateOfMind.Kind.dailyMood.rawValue
                  && state.etichette_raw == mind.labels.map(\.rawValue)
                  && state.associazioni_raw == mind.associations.map(\.rawValue), "state_of_mind_raw_values")
        try check(state.fine == ISO.string(mind.endDate) && state.metadati?[HKMetadataKeyTimeZone] == "Asia/Tokyo", "state_of_mind_end_and_metadata")
        print("Serialization contract tests: \(passed) passed. Synthetic objects only; no HealthKit store access.")
    }
}
