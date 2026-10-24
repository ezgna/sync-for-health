import CryptoKit
import Foundation

/// A JSON value used only for transport, without converting numbers to strings.
enum WireJSON: Codable, Sendable {
    case object([String: WireJSON]), array([WireJSON]), string(String)
    case integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: WireJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([WireJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: WireJSON]? { if case .object(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
}

/// Every part has its own normal v2 durable ACK. The sample cursor moves only
/// after all parts are acknowledged; the receiver assembles the original JSON
/// and commits its record atomically. A retry uses the same content digest.
struct RecordFrames: Sequence, Sendable {
    static let chunkBytes = 2 * 1024 * 1024
    static let maxRecordBytes = 256 * 1024 * 1024
    let data: Data
    let section: String
    let uuid: String
    let digest: String
    let installation: String
    let destination: String
    let device: String
    let sentAt: String
    let single: WireJSON?

    enum Failure: Error { case invalidRecord, recordTooLarge }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    init(data: Data, section: String, installation: String, destination: String,
         device: String, sentAt: String) throws {
        guard data.count <= Self.maxRecordBytes else { throw Failure.recordTooLarge }
        let json = try JSONDecoder().decode(WireJSON.self, from: data)
        guard let uuid = json.object?["uuid"]?.string, UUID(uuidString: uuid) != nil else {
            throw Failure.invalidRecord
        }
        self.data = data; self.section = section; self.uuid = uuid
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.installation = installation; self.destination = destination
        self.device = device; self.sentAt = sentAt
        // Leave room for the envelope. Small records keep the ordinary schema.
        single = data.count < 7 * 1024 * 1024 ? json : nil
    }

    func makeIterator() -> Iterator { Iterator(frames: self) }
    struct Iterator: IteratorProtocol {
        let frames: RecordFrames
        var index = 0
        mutating func next() -> WireEnvelope? {
            let fields: [String: WireJSON]
            if let single = frames.single {
                guard index == 0 else { return nil }
                fields = [frames.section: .array([single])]
            } else {
                let total = (frames.data.count + RecordFrames.chunkBytes - 1) / RecordFrames.chunkBytes
                guard index < total else { return nil }
                let lower = index * RecordFrames.chunkBytes
                let upper = Swift.min(lower + RecordFrames.chunkBytes, frames.data.count)
                fields = ["frammenti": .array([.object([
                    "record_uuid": .string(frames.uuid), "section": .string(frames.section),
                    "sha256": .string(frames.digest), "index": .integer(Int64(index)),
                    "total": .integer(Int64(total)),
                    "data_base64": .string(frames.data.subdata(in: lower..<upper).base64EncodedString())
                ])])]
            }
            index += 1
            return WireEnvelope(installation: frames.installation, destination: frames.destination,
                                device: frames.device, sentAt: frames.sentAt, fields: fields)
        }
    }
}

struct WireEnvelope: Encodable, Sendable {
    let installation: String
    let destination: String
    let device: String
    let sentAt: String
    let fields: [String: WireJSON]
    let batchID = UUID().uuidString
    func encode(to encoder: Encoder) throws {
        var all = fields
        all["app"] = .string("salute-libera")
        all["versione"] = .integer(2)
        all["batch_id"] = .string(batchID)
        all["installation_id"] = .string(installation)
        all["destination_id"] = .string(destination)
        all["dispositivo"] = .string(device)
        all["inviato"] = .string(sentAt)
        try WireJSON.object(all).encode(to: encoder)
    }
}

/// This identity belongs to a HealthBridge snapshot, never to an HKObject.
enum SnapshotIdentity {
    static func uuid(installation: String, kind: String) -> String {
        var b = Array(SHA256.hash(data: Data("HealthBridge.snapshot|\(installation)|\(kind)".utf8)).prefix(16))
        b[6] = (b[6] & 15) | 0x80; b[8] = (b[8] & 63) | 0x80
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15])).uuidString
    }
}

struct HealthSnapshotRecord<Row: Encodable & Sendable>: Encodable, Sendable {
    let uuid: String
    let tipo: String
    let inizio: String
    let fine: String
    let fonte = "HealthKit"
    let identity_kind = "healthbridge_snapshot"
    let read_completeness = "unknown"
    let records: [Row]
    var fuso_orario: String?
}
