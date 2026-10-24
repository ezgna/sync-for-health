import Compression
import CryptoKit
import Foundation

/// Deliberately contains only fixed codes. Server bodies and NSError messages may
/// contain measurements, URLs or credentials and must never enter an error/log.
enum UploadError: LocalizedError, Sendable {
    case noEndpoint
    case invalidEndpoint
    case invalidToken
    case invalidPayload
    case invalidAcknowledgement
    case redirect
    case http(Int)
    case network(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noEndpoint:
            String(localized: "Nessun indirizzo di destinazione configurato.")
        case .invalidEndpoint:
            String(localized: "Indirizzo non valido: serve HTTPS senza credenziali, query o frammenti.")
        case .invalidToken:
            String(localized: "Configura un token valido senza interruzioni di riga.")
        case .invalidPayload:
            String(localized: "Il blocco da inviare non rispetta il protocollo 2.")
        case .invalidAcknowledgement:
            String(localized: "Il server non ha confermato il salvataggio del blocco. Nessun avanzamento della sincronizzazione.")
        case .redirect:
            String(localized: "Il server ha risposto con un reindirizzamento. Configura direttamente l'indirizzo HTTPS finale.")
        case .http(let code) where code == 401 || code == 403:
            String(localized: "Il server ha rifiutato il token (\(code)). Controllalo nelle Impostazioni.")
        case .http(let code) where code == 404:
            String(localized: "Indirizzo non trovato sul server (404).")
        case .http(let code) where code == 413:
            String(localized: "Il server ha rifiutato un blocco troppo grande (413).")
        case .http(let code):
            String(localized: "Il server ha risposto con HTTP \(code).")
        case .network(let code):
            String(localized: "Invio non riuscito per un errore di rete (\(code)).")
        case .cancelled:
            String(localized: "Invio interrotto.")
        }
    }

    var diagnosticCode: String {
        switch self {
        case .noEndpoint: "upload.no_endpoint"
        case .invalidEndpoint: "upload.invalid_endpoint"
        case .invalidToken: "upload.invalid_token"
        case .invalidPayload: "upload.invalid_payload"
        case .invalidAcknowledgement: "upload.invalid_ack"
        case .redirect: "upload.redirect_rejected"
        case .http(let code): "upload.http.\(code)"
        case .network(let code): "upload.network.\(code)"
        case .cancelled: "upload.cancelled"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network: true
        case .http(let code): code == 408 || code == 429 || code >= 500
        default: false
        }
    }
}

/// Never forward Authorization (even to another path on the same host).
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Authenticated protocol-2 POST. A status code alone never acknowledges a batch.
struct Uploader: Sendable {
    let endpoint: URL
    let token: String
    let gzip: Bool
    var logRequests = true

    static let maxAcknowledgementBytes = 8 * 1024
    private static let session = makeSession()

    /// Ephemeral sessions do not share cookies, cached responses or credentials.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private struct Envelope: Decodable {
        let batchID: UUID
        let kind: String
        enum CodingKeys: String, CodingKey {
            case versione, batch_id, installation_id, destination_id, prova, diagnostica
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(Int.self, forKey: .versione) == 2 else {
                throw UploadError.invalidPayload
            }
            batchID = try container.decode(UUID.self, forKey: .batch_id)
            _ = try container.decode(UUID.self, forKey: .installation_id)
            _ = try container.decode(UUID.self, forKey: .destination_id)
            let probe = try container.decodeIfPresent(Bool.self, forKey: .prova) ?? false
            let diagnostic = container.contains(.diagnostica)
            guard !(probe && diagnostic) else { throw UploadError.invalidPayload }
            kind = probe ? "probe" : diagnostic ? "diagnostic" : "health"
        }
    }

    private struct Acknowledgement: Decodable {
        let ok: Bool
        let protocol_version: Int
        let batch_id: UUID
        let body_sha256: String
        let committed: Bool
        let kind: String
    }

    /// Shared by health pages, connection probes and explicitly enabled diagnostics.
    /// The hash covers the exact uncompressed JSON bytes, unchanged across retries.
    @discardableResult
    func send<T: Encodable & Sendable>(_ payload: T, attempts: Int = 4) async throws -> Int {
        try await performSend(payload, attempts: attempts, session: Self.session)
    }

    #if TRANSPORT_CONTRACT_TESTS
    /// Not compiled into the iPhone app. Enables offline URLProtocol tests only.
    @discardableResult
    func send<T: Encodable & Sendable>(_ payload: T, attempts: Int, session: URLSession) async throws -> Int {
        try await performSend(payload, attempts: attempts, session: session)
    }
    @discardableResult
    func sendJSONForContractTests(_ json: Data, attempts: Int, session: URLSession) async throws -> Int {
        try await performSendJSON(json, attempts: attempts, session: session)
    }
    #endif

    private func performSend<T: Encodable & Sendable>(_ payload: T, attempts: Int, session: URLSession) async throws -> Int {
        let json: Data
        do { json = try Self.encoder.encode(payload) } catch { throw UploadError.invalidPayload }
        return try await performSendJSON(json, attempts: attempts, session: session)
    }

    private func performSendJSON(_ json: Data, attempts: Int, session: URLSession) async throws -> Int {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host() != nil,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw UploadError.invalidEndpoint }
        let authorization = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorization.isEmpty, !authorization.unicodeScalars.contains(where: CharacterSet.newlines.contains) else {
            throw UploadError.invalidToken
        }
        try Self.checkCancellation()
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: json) }
        catch { throw UploadError.invalidPayload }
        let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        var body = json
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("SyncForHealth/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        if gzip, let compressed = Gzip.compress(json) {
            body = compressed
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        request.httpBody = body

        let attemptLimit = max(1, attempts)
        var delay: Duration = .seconds(2)
        var lastError: UploadError = .network(0)
        for attempt in 1...attemptLimit {
            let started = Date()
            do {
                try Self.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw UploadError.invalidAcknowledgement }
                if (300..<400).contains(http.statusCode) { throw UploadError.redirect }
                guard http.statusCode == 200 else { throw UploadError.http(http.statusCode) }
                let mime = http.value(forHTTPHeaderField: "Content-Type")?
                    .split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard mime == "application/json" else { throw UploadError.invalidAcknowledgement }
                if http.expectedContentLength > Int64(Self.maxAcknowledgementBytes) {
                    throw UploadError.invalidAcknowledgement
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < Self.maxAcknowledgementBytes else { throw UploadError.invalidAcknowledgement }
                    data.append(byte)
                }
                try Self.checkCancellation()
                guard let ack = try? JSONDecoder().decode(Acknowledgement.self, from: data),
                      ack.ok, ack.committed, ack.protocol_version == 2,
                      ack.batch_id == envelope.batchID, ack.body_sha256 == digest,
                      ack.kind == envelope.kind else { throw UploadError.invalidAcknowledgement }
                if logRequests {
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    DiagLog.info("rete", "POST confermato: \(body.count) byte, \(ms) ms, tentativo \(attempt)/\(attemptLimit)")
                }
                return body.count
            } catch is CancellationError {
                throw UploadError.cancelled
            } catch let error as URLError where error.code == .cancelled {
                throw UploadError.cancelled
            } catch let error as UploadError {
                lastError = error
            } catch {
                lastError = .network((error as NSError).code)
            }
            if logRequests { DiagLog.warning("rete", "POST non confermato: \(lastError.diagnosticCode), tentativo \(attempt)/\(attemptLimit)") }
            guard lastError.isRetryable, attempt < attemptLimit else { break }
            do { try await Task.sleep(for: delay) } catch { throw UploadError.cancelled }
            delay *= 3
        }
        throw lastError
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw UploadError.cancelled }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static let deviceModel: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}

/// Compressione gzip (RFC 1952) con il framework Compression (deflate grezzo) + CRC32.
enum Gzip {
    static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = max(64, input.count + input.count / 10 + 64)
        var deflated = Data(count: capacity)
        let size = deflated.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { return nil }
        deflated.count = size

        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(deflated)
        var crc = crc32(input).littleEndian
        var length = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
