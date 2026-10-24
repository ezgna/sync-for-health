import Compression
import CryptoKit
import Foundation

private struct SyntheticPayload: Encodable, Sendable {
    var versione = 2
    var batch_id = UUID().uuidString
    var installation_id = UUID().uuidString
    var destination_id = UUID().uuidString
    var prova: Bool? = nil
    var diagnostica: [String: String]? = nil
}

private enum Mode: Sendable {
    case valid, html, accepted202, redirect302, badBatch, badHash, notCommitted, wrongKind
    case wrongProtocol, oversized, error422, cancelled, timeout, truncated, gzip, hanging
}

private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Mode = .valid
    private var requests = 0
    private var authorization = ""
    func reset(_ mode: Mode) { lock.withLock { current = mode; requests = 0; authorization = "" } }
    func accept(_ request: URLRequest) -> Mode {
        lock.withLock { requests += 1; authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""; return current }
    }
    var count: Int { lock.withLock { requests } }
    var header: String { lock.withLock { authorization } }
}

private final class SyntheticProtocol: URLProtocol, @unchecked Sendable {
    static let state = FixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.accept(request)
        if mode == .hanging { return }
        if mode == .cancelled || mode == .timeout {
            client?.urlProtocol(self, didFailWithError: URLError(mode == .cancelled ? .cancelled : .timedOut,
                userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC_SECRET_MUST_NOT_ESCAPE"]))
            return
        }
        var json = request.httpBody ?? Data()
        if json.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                json.append(contentsOf: buffer.prefix(count))
            }
        }
        if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
            let capacity = 64 * 1024
            var decoded = Data(count: capacity)
            let compressed = json.subdata(in: 10..<(json.count - 8))
            let count = decoded.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
                }
            }
            decoded.count = count
            json = decoded
        }
        let envelope = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let kind = envelope["prova"] as? Bool == true ? "probe" : envelope["diagnostica"] != nil ? "diagnostic" : "health"
        var ack: [String: Any] = ["ok": true, "protocol_version": 2,
            "batch_id": envelope["batch_id"] ?? "missing",
            "body_sha256": SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined(),
            "committed": true, "kind": kind]
        switch mode {
        case .badBatch: ack["batch_id"] = UUID().uuidString
        case .badHash: ack["body_sha256"] = String(repeating: "0", count: 64)
        case .notCommitted: ack["committed"] = false
        case .wrongKind: ack["kind"] = "wrong"
        case .wrongProtocol: ack["protocol_version"] = 1
        default: break
        }
        var body = (try? JSONSerialization.data(withJSONObject: ack)) ?? Data()
        var code = 200
        var headers = ["Content-Type": "application/json"]
        switch mode {
        case .html: body = Data("<html>SYNTHETIC_SECRET_MUST_NOT_ESCAPE</html>".utf8); headers["Content-Type"] = "text/html"
        case .accepted202: code = 202
        case .redirect302: code = 302; headers["Location"] = "https://elsewhere.invalid/stolen"
        case .oversized: body = Data(repeating: 65, count: 9 * 1024)
        case .error422: code = 422; body = Data("SYNTHETIC_SECRET_MUST_NOT_ESCAPE".utf8)
        case .truncated: body = Data("{\"ok\":true}".utf8)
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func received(_ request: URLRequest?) { lock.withLock { value = request == nil } }
    var rejected: Bool { lock.withLock { value } }
}

@main private enum TransportContractTests {
    static func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }

    static func checkRedirect(_ session: URLSession, from endpoint: URL, to destination: URL) {
        let result = RedirectResult()
        let delegate = session.delegate as! any URLSessionTaskDelegate
        let task = session.dataTask(with: endpoint)
        let response = HTTPURLResponse(url: endpoint, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
        delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: URLRequest(url: destination), completionHandler: { result.received($0) })
        require(result.rejected, "delegate rejects same-host and cross-host redirects")
        task.cancel()
    }

    static func main() async throws {
        let session = Uploader.makeSession(protocolClasses: [SyntheticProtocol.self])
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        require(configuration.urlCache == nil, "no shared cache")
        require(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies, "no cookie storage")
        require(configuration.urlCredentialStorage == nil, "no credential storage")
        require(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData, "no cache reuse")

        let uploader = Uploader(endpoint: URL(string: "https://synthetic.invalid/ingest")!,
                                token: " \nsynthetic-token\t", gzip: false, logRequests: false)
        for (mode, name) in [(Mode.valid, "valid health ACK"), (.valid, "probe ACK"), (.valid, "diagnostic ACK"), (.gzip, "gzip hashes uncompressed bytes")] {
            SyntheticProtocol.state.reset(mode)
            var payload = SyntheticPayload()
            if name == "probe ACK" { payload.prova = true }
            if name == "diagnostic ACK" { payload.diagnostica = ["test": "synthetic"] }
            var sender = uploader
            if mode == .gzip { sender = Uploader(endpoint: uploader.endpoint, token: uploader.token, gzip: true, logRequests: false) }
            _ = try await sender.send(payload, attempts: 1, session: session)
            require(SyntheticProtocol.state.count == 1, name)
            require(SyntheticProtocol.state.header == "Bearer synthetic-token", "trim bearer consistently: \(name)")
        }

        for (mode, name) in [(Mode.html, "reject HTML200"), (.accepted202, "reject 202 before commit"), (.redirect302, "reject redirect status"),
                             (.badBatch, "reject different batch"), (.badHash, "reject different bytes"), (.notCommitted, "reject uncommitted ACK"),
                             (.wrongKind, "reject different kind"), (.wrongProtocol, "reject protocol1 ACK"), (.oversized, "bound ACK bytes"),
                             (.error422, "discard server error body"), (.cancelled, "cancel is not retried"), (.timeout, "discard network description"),
                             (.truncated, "reject incomplete ACK")] {
            SyntheticProtocol.state.reset(mode)
            do {
                _ = try await uploader.send(SyntheticPayload(), attempts: 1, session: session)
                fatalError("Unexpected success: \(name)")
            } catch let error as UploadError {
                require(!(error.errorDescription ?? "").contains("SYNTHETIC_SECRET"), "no secret in error: \(name)")
                require(!DiagLog.describe(error).contains("SYNTHETIC_SECRET"), "no secret in diagnostic: \(name)")
                if mode == .cancelled {
                    if case .cancelled = error {} else { fatalError("Cancellation misclassified") }
                }
                require(SyntheticProtocol.state.count == 1, name)
            }
        }

        for address in ["http://127.0.0.1/ingest", "https://user:secret@synthetic.invalid/ingest", "https://synthetic.invalid/ingest?t=secret", "https://synthetic.invalid/ingest#secret"] {
            SyntheticProtocol.state.reset(.valid)
            let bad = Uploader(endpoint: URL(string: address)!, token: "synthetic", gzip: false, logRequests: false)
            do { _ = try await bad.send(SyntheticPayload(), attempts: 1, session: session); fatalError("Invalid endpoint accepted") }
            catch UploadError.invalidEndpoint { require(SyntheticProtocol.state.count == 0, "reject endpoint before network") }
        }
        for token in [" \n\t", "synthetic\r\nInjected: value"] {
            SyntheticProtocol.state.reset(.valid)
            let bad = Uploader(endpoint: uploader.endpoint, token: token, gzip: false, logRequests: false)
            do { _ = try await bad.send(SyntheticPayload(), attempts: 1, session: session); fatalError("Invalid token accepted") }
            catch UploadError.invalidToken { require(SyntheticProtocol.state.count == 0, "reject invalid bearer before network") }
        }
        SyntheticProtocol.state.reset(.hanging)
        let active = Task { try await uploader.send(SyntheticPayload(), attempts: 4, session: session) }
        while SyntheticProtocol.state.count == 0 { await Task.yield() }
        active.cancel()
        do { _ = try await active.value; fatalError("Cancelled task completed successfully") }
        catch UploadError.cancelled { require(SyntheticProtocol.state.count == 1, "Task cancellation interrupts in-flight request without retry") }

        SyntheticProtocol.state.reset(.valid)
        var legacy = SyntheticPayload(); legacy.versione = 1
        do { _ = try await uploader.send(legacy, attempts: 1, session: session); fatalError("Legacy envelope accepted") }
        catch UploadError.invalidPayload { require(SyntheticProtocol.state.count == 0, "reject protocol1 payload before network") }

        let secretError = NSError(domain: "SYNTHETIC_SECRET_DOMAIN", code: 37,
            userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC_SECRET_DESCRIPTION", NSUnderlyingErrorKey: NSError(domain: "SYNTHETIC_SECRET", code: 9)])
        require(DiagLog.describe(secretError) == "other.37", "redact arbitrary domain, description, userInfo and underlying error")
        let diagnosticResult = await DiagShipper.shared.ship()
        require(diagnosticResult != nil, "diagnostics require explicit opt-in")

        for destination in ["https://synthetic.invalid/other", "https://elsewhere.invalid/ingest"] {
            checkRedirect(session, from: uploader.endpoint, to: URL(string: destination)!)
        }
        print("All transport tests passed. All data and credentials are synthetic; URLProtocol prevented external network.")
    }
}
