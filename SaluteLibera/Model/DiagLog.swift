import Foundation
import os

/// Registro diagnostico: file di testo a rotazione + os.Logger con gli stessi messaggi.
///
/// Percorso (nel contenitore dati dell'app):
///   Library/Application Support/Log/salute-libera.log     (corrente, max ~2 MB)
///   Library/Application Support/Log/salute-libera.1.log   (precedente)
///   Library/Application Support/Log/da-inviare.log        (righe non ancora spedite al server)
///
/// Regola: MAI valori di salute nel registro, solo conteggi, tipi, esiti ed errori.
enum DiagLog {
    enum Level: String, Sendable { case info = "INFO", warning = "WARN", error = "ERRORE" }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Log", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Storage.excludeFromBackup(&dir)
        // Scrivibile anche in background con l'iPhone bloccato (dopo il primo sblocco).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        return dir
    }()

    static let fileURL = directory.appendingPathComponent("salute-libera.log")
    static let previousURL = directory.appendingPathComponent("salute-libera.1.log")
    static let pendingURL = directory.appendingPathComponent("da-inviare.log")

    static let maxBytes = 2 * 1024 * 1024
    /// Massimo di righe spedite (e trattenute in attesa di spedizione).
    static let maxPending = 300

    private static let queue = DispatchQueue(label: "it.vcnngr.syncforhealth.log")
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.ezgna.healthbridge", category: "diagnostica")

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func info(_ category: String, _ message: String) { write(.info, category, message) }
    static func warning(_ category: String, _ message: String) { write(.warning, category, message) }
    static func error(_ category: String, _ message: String) { write(.error, category, message) }

    /// Only allowlisted domain labels and numeric codes: never NSError descriptions,
    /// userInfo, URLs, response bodies or nested provider text.
    static func describe(_ error: Error) -> String {
        if let upload = error as? UploadError { return upload.diagnosticCode }
        let ns = error as NSError
        return "\(safeDomain(ns.domain)).\(ns.code)"
    }

    private static func safeDomain(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain: "url"
        case NSCocoaErrorDomain: "cocoa"
        case NSPOSIXErrorDomain: "posix"
        case NSOSStatusErrorDomain: "osstatus"
        case "com.apple.healthkit", "HKErrorDomain": "healthkit"
        case "BGTaskSchedulerErrorDomain": "background"
        default: "other"
        }
    }

    /// Old versions could include server error bodies in pending diagnostics.
    /// Discard those diagnostic files once rather than upload legacy private data.
    /// Must run on queue before reading/writing the files.
    private static func preparePrivacyFormat() -> Bool {
        let key = "diagnosticaPrivacyFormatVersion"
        guard UserDefaults.standard.integer(forKey: key) < 2 else { return true }
        let files = FileManager.default
        do {
            for url in [fileURL, previousURL, pendingURL] where files.fileExists(atPath: url.path) {
                try files.removeItem(at: url)
            }
            UserDefaults.standard.set(2, forKey: key)
            return true
        } catch {
            // Never read or ship a legacy file if cleanup could not be completed.
            return false
        }
    }

    static func write(_ level: Level, _ category: String, _ message: String) {
        switch level {
        case .info: logger.info("[\(category, privacy: .public)] \(message, privacy: .private)")
        case .warning: logger.warning("[\(category, privacy: .public)] \(message, privacy: .private)")
        case .error: logger.error("[\(category, privacy: .public)] \(message, privacy: .private)")
        }
        let date = Date()
        queue.async {
            guard preparePrivacyFormat() else { return }
            let line = "\(stamp.string(from: date)) [\(level.rawValue)] [\(category)] \(message)\n"
            append(line, to: fileURL)
            append(line, to: pendingURL)
            rotateIfNeeded()
        }
    }

    // MARK: Lettura

    /// Ultime `count` righe (file precedente incluso se serve).
    static func tail(_ count: Int) -> [String] {
        queue.sync {
            guard preparePrivacyFormat() else { return [] }
            var lines = readLines(fileURL)
            if lines.count < count { lines = readLines(previousURL) + lines }
            return Array(lines.suffix(count))
        }
    }

    /// Righe in attesa di spedizione (al massimo le ultime 300) e la dimensione letta,
    /// da passare a `markShipped` dopo un ACK protocollo 2 verificato.
    static func pending() -> (lines: [String], bytes: Int) {
        queue.sync {
            guard preparePrivacyFormat() else { return ([], 0) }
            let data = (try? Data(contentsOf: pendingURL)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return (Array(lines.suffix(maxPending)), data.count)
        }
    }

    /// Rimuove dalle righe in attesa i primi `bytes` byte (quelli spediti con successo).
    static func markShipped(bytes: Int) {
        queue.async {
            guard preparePrivacyFormat() else { return }
            guard let data = try? Data(contentsOf: pendingURL) else { return }
            let rest = data.count > bytes ? data.subdata(in: bytes..<data.count) : Data()
            try? rest.write(to: pendingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static var totalSize: Int {
        let fm = FileManager.default
        return [fileURL, previousURL].reduce(0) {
            $0 + ((try? fm.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0)
        }
    }

    // MARK: Interni (sempre sulla coda)

    private static func append(_ line: String, to url: URL) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: fileURL, to: previousURL)
        }
        // Le righe in attesa non crescono oltre ~2× il massimo spedibile.
        if let size = try? fm.attributesOfItem(atPath: pendingURL.path)[.size] as? Int, size > 256 * 1024,
           let data = try? Data(contentsOf: pendingURL) {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(maxPending)
            try? Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: pendingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: Contesto

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static var iosVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// Spedizione delle righe diagnostiche al server (POST separato, mai bloccante).
actor DiagShipper {
    static let shared = DiagShipper()
    static let minInterval: TimeInterval = 15 * 60
    private static let lastKey = "diagnosticaUltimoInvio"

    private var inFlight = false
    private var uploadTask: Task<Int, Error>?
    private var runningRevision: UUID?
    private var cancellationGeneration: UInt = 0

    /// Called on every settings change, alongside cancellation of regular syncs.
    func cancel() {
        cancellationGeneration &+= 1
        uploadTask?.cancel()
    }

    /// Ignore delayed notifications for older settings and never cancel a task
    /// which already uses the current revision.
    func cancelStale(revision: UUID) async {
        let currentRevision = await MainActor.run { AppSettings.shared.snapshot.revision }
        guard currentRevision == revision, let runningRevision, runningRevision != revision else { return }
        cancel()
    }

    struct Body: Encodable, Sendable {
        var app = "salute-libera"
        var versione = 2
        var batch_id = UUID().uuidString
        let installation_id: String
        let destination_id: String
        let diagnostica: Diagnostics
    }

    struct Diagnostics: Encodable, Sendable {
        let versione_app: String
        let build: String
        let ios: String
        let dispositivo: String
        let righe: [String]
    }

    /// Dopo una sincronizzazione: spedisce solo se sono passati almeno 15 minuti.
    func shipIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.lastKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.minInterval else { return }
        _ = await ship()
    }

    /// Spedisce subito. Ritorna nil se riuscito, altrimenti il messaggio d'errore.
    @discardableResult
    func ship() async -> String? {
        guard !inFlight else { return nil }
        inFlight = true
        let generation = cancellationGeneration
        defer { inFlight = false; uploadTask = nil; runningRevision = nil }
        let settings = await MainActor.run { AppSettings.shared.snapshot }
        runningRevision = settings.revision
        guard !AppEnvironment.isDemo, settings.syncEnabled, settings.diagnosticsEnabled else {
            return String(localized: "Invio diagnostica disattivato nelle Impostazioni.")
        }
        guard let endpoint = settings.endpoint else {
            return String(localized: "Nessun indirizzo di destinazione configurato.")
        }
        let pending = DiagLog.pending()
        guard !pending.lines.isEmpty else { return nil }
        let body = Body(installation_id: settings.installationID, destination_id: settings.destinationID,
                        diagnostica: Diagnostics(
            versione_app: DiagLog.appVersion, build: DiagLog.appBuild, ios: DiagLog.iosVersion,
            dispositivo: Uploader.deviceModel, righe: pending.lines))
        let uploader = Uploader(endpoint: endpoint, token: settings.token, gzip: settings.gzip, logRequests: false)
        do {
            // Settings changes cancel regular syncs. Diagnostics also recheck the
            // opt-in and snapshot immediately before creating their HTTP request.
            guard await MainActor.run(body: {
                !AppEnvironment.isDemo && AppSettings.shared.isCurrent(settings) && AppSettings.shared.syncEnabled
                    && AppSettings.shared.diagnosticsEnabled
            }), generation == cancellationGeneration else {
                return String(localized: "Impostazioni modificate: invio diagnostica interrotto.")
            }
            try Task.checkCancellation()
            let task = Task { try await uploader.send(body, attempts: 1) }
            uploadTask = task
            _ = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == cancellationGeneration else { throw UploadError.cancelled }
            DiagLog.markShipped(bytes: pending.bytes)
            UserDefaults.standard.set(Date(), forKey: Self.lastKey)
            DiagLog.info("diagnostica", "spedite \(pending.lines.count) righe al server")
            return nil
        } catch {
            DiagLog.warning("diagnostica", "spedizione non riuscita: \(DiagLog.describe(error))")
            return (error as? UploadError)?.errorDescription ?? DiagLog.describe(error)
        }
    }
}
