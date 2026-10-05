import Compression
import Foundation
import UIKit

enum UploadError: LocalizedError, Sendable {
    case noEndpoint
    case http(Int, String?)
    case network(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noEndpoint:
            String(localized: "Nessun indirizzo di destinazione configurato.")
        case .http(let code, _) where code == 401 || code == 403:
            String(localized: "Il server ha rifiutato il token (\(code)). Controllalo nelle Impostazioni.")
        case .http(let code, _) where code == 404:
            String(localized: "Indirizzo non trovato sul server (404).")
        case .http(let code, _) where code == 413:
            String(localized: "Il server ha rifiutato un blocco troppo grande (413).")
        case .http(let code, _) where code >= 500:
            String(localized: "Il server ha un problema temporaneo (\(code)).")
        case .http(let code, let body):
            if let body, !body.isEmpty {
                String(localized: "Il server ha risposto \(code): \(body)")
            } else {
                String(localized: "Il server ha risposto \(code).")
            }
        case .network(let message):
            message
        case .cancelled:
            String(localized: "Invio interrotto.")
        }
    }

    /// Vale la pena ritentare? (errori di rete, 408, 429 e 5xx)
    var isRetryable: Bool {
        switch self {
        case .network: true
        case .http(let code, _): code == 408 || code == 429 || code >= 500
        default: false
        }
    }
}

/// Invia i payload in POST JSON, con gzip opzionale e tentativi ripetuti con attesa crescente.
struct Uploader: Sendable {
    let endpoint: URL
    let token: String
    let gzip: Bool
    /// Scrive nel registro diagnostico ogni POST (disattivato per la spedizione della diagnostica).
    var logRequests = true

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// Ritorna il numero di byte inviati (dopo l'eventuale compressione).
    @discardableResult
    func send<T: Encodable & Sendable>(_ payload: T, attempts: Int = 4) async throws -> Int {
        let json = try Self.encoder.encode(payload)
        var body = json
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SyncForHealth/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if gzip, let compressed = Gzip.compress(json) {
            body = compressed
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        request.httpBody = body

        var delay: Duration = .seconds(2)
        var lastError: UploadError = .network("?")
        let host = endpoint.host() ?? "?"
        let size = "\(body.count) byte\(request.value(forHTTPHeaderField: "Content-Encoding") != nil ? " gzip (\(json.count) in chiaro)" : "")"
        for attempt in 1...max(1, attempts) {
            let started = Date()
            func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
            do {
                try Task.checkCancellation()
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    if logRequests {
                        DiagLog.info("rete", "POST \(host) \(size) → HTTP \(code) in \(ms()) ms, tentativo \(attempt)/\(attempts)")
                    }
                    return body.count
                }
                let snippet = String(data: data.prefix(160), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = .http(code, snippet)
                if logRequests {
                    DiagLog.warning("rete", "POST \(host) \(size) → HTTP \(code) in \(ms()) ms, tentativo \(attempt)/\(attempts)")
                }
            } catch is CancellationError {
                if logRequests { DiagLog.warning("rete", "POST \(host) annullato (tentativo \(attempt))") }
                throw UploadError.cancelled
            } catch let error as URLError where error.code == .cancelled {
                if logRequests { DiagLog.warning("rete", "POST \(host) annullato (tentativo \(attempt))") }
                throw UploadError.cancelled
            } catch {
                lastError = .network(error.localizedDescription)
                if logRequests {
                    DiagLog.warning("rete", "POST \(host) \(size) fallito in \(ms()) ms, tentativo \(attempt)/\(attempts): \(DiagLog.describe(error))")
                }
            }
            guard lastError.isRetryable, attempt < attempts else { break }
            do { try await Task.sleep(for: delay) } catch { throw UploadError.cancelled }
            delay *= 3
        }
        throw lastError
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Identificativo del modello, es. "iPhone17,1".
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
