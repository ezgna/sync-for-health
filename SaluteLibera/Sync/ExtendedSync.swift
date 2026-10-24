import CryptoKit
import Foundation
import HealthKit

extension SyncJob {
    /// Updating an anchor is the caller's responsibility, after every frame ACK.
    func sendRecordData(_ data: Data, section: String, uploader: Uploader,
                        record: inout SyncRecord) async throws {
        let frames = try RecordFrames(data: data, section: section,
                                      installation: settings.installationID, destination: settings.destinationID,
                                      device: Uploader.deviceModel, sentAt: ISO.string(.now))
        for envelope in frames {
            try await ensureCurrent()
            guard try RecordFrames.encode(envelope).count <= Self.maxPayloadBytes else {
                throw Failure.oversizedRecord
            }
            record.bytes += try await uploader.send(envelope)
            record.requests += 1
            try await ensureCurrent()
        }
        record.samples += 1
    }

    func sendExtended(_ sample: HKSample, uploader: Uploader,
                      record: inout SyncRecord) async throws {
        let extra = try await ExtendedHealth.sample(sample, store: Health.store)
        try await sendRecordData(RecordFrames.encode(extra), section: extra.section,
                                 uploader: uploader, record: &record)
    }

    /// Activity summaries and the medication catalog do not expose HKQueryAnchor.
    /// Query every accessible row, send changed snapshots as one atomic record,
    /// then persist the digest only after all HTTP frames have durable ACKs.
    func syncSupplementalSnapshots(uploader: Uploader, record: inout SyncRecord) async throws -> Set<String> {
        var pendingTypes: Set<String> = []
        if settings.groups.contains(.attivita) {
            do {
                try await ensureCurrent()
                let zone = TimeZone.current
                let rows = try await ExtendedHealth.activitySummaries(store: Health.store, timeZone: zone)
                try await sendSnapshot(rows, kind: "activity", type: "HealthBridgeActivitySummarySnapshot",
                                       section: "riepiloghi_attivita", timeZone: zone.identifier,
                                       uploader: uploader, record: &record)
            } catch {
                guard Self.isReadAuthorizationError(error) else { throw error }
                pendingTypes.insert(HKObjectType.activitySummaryType().identifier)
            }
        }
        if settings.groups.contains(.glicemia) {
            do {
                try await ensureCurrent()
                let rows = try await ExtendedHealth.medications(store: Health.store)
                try await sendSnapshot(rows, kind: "medications", type: "HealthBridgeMedicationSnapshot",
                                       section: "farmaci", uploader: uploader, record: &record)
            } catch {
                guard Self.isReadAuthorizationError(error) else { throw error }
                pendingTypes.insert(HKObjectType.userAnnotatedMedicationType().identifier)
            }
        }
        return pendingTypes
    }

    private func sendSnapshot<Row: Encodable & Sendable>(
        _ rows: [Row], kind: String, type: String, section: String, timeZone: String? = nil,
        uploader: Uploader, record: inout SyncRecord
    ) async throws {
        let content = try RecordFrames.encode(rows)
        var input = content
        input.append(Data((timeZone ?? "").utf8))
        let digest = Data(SHA256.hash(data: input))
        let key = "healthbridge.snapshot.\(kind).digest.v1"
        let store = AnchorStore.shared
        if try store.data(for: key, destination: settings.destinationID) == digest { return }
        let now = ISO.string(.now)
        let snapshot = HealthSnapshotRecord(
            uuid: SnapshotIdentity.uuid(installation: settings.installationID, kind: kind),
            tipo: type, inizio: now, fine: now, records: rows, fuso_orario: timeZone)
        try await sendRecordData(RecordFrames.encode(snapshot), section: section,
                                 uploader: uploader, record: &record)
        try await ensureCurrent()
        try store.commit([key: digest], destination: settings.destinationID)
    }
}
