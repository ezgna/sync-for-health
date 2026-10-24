import Foundation
import Observation
import Security

/// URL and credential are saved together, so a crash cannot pair a token with another host.
struct SavedConnection: Codable, Equatable {
    var endpoint: String
    var token: String
    var connectionID: String
}

enum ConnectionPolicy {
    static func url(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil else { return nil }
        guard !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        return parts.url
    }

    static func token(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...256).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else { return nil }
        return value
    }
}

enum SettingsError: LocalizedError {
    case invalidConnection, credentialsUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidConnection: "HTTPS URL（認証情報・クエリ・フラグメントなし）と、32〜256文字の半角英数字・記号のトークンを指定してください。"
        case .credentialsUnavailable: "接続設定を安全に保存できませんでした。iPhoneをロック解除して再試行してください。"
        }
    }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard
    private var connectionID: String
    private var credentialsLoaded: Bool
    private(set) var endpoint: String
    private(set) var token: String
    private(set) var destinationID: String
    let installationID: String
    private(set) var revision = UUID()

    var gzip: Bool { didSet { defaults.set(gzip, forKey: Keys.gzip); changed() } }
    var includeRoutes: Bool { didSet { defaults.set(includeRoutes, forKey: Keys.routes); changed(resetHistory: true) } }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Keys.onboarding) } }
    var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: Keys.enabled); changed() } }
    var diagnosticsEnabled: Bool { didSet { defaults.set(diagnosticsEnabled, forKey: Keys.diagnostics); changed() } }
    var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: Keys.demo); changed(); DemoMode.apply(demoMode) }
    }
    var enabledGroups: Set<DataGroup> {
        didSet {
            defaults.set(enabledGroups.map(\.rawValue).sorted(), forKey: Keys.groups)
            changed(resetHistory: true)
        }
    }

    private init() {
        let d = UserDefaults.standard
        let saved: SavedConnection?
        do { saved = try Keychain.connection(); credentialsLoaded = true }
        catch { saved = nil; credentialsLoaded = false }
        endpoint = saved?.endpoint ?? ""
        token = saved?.token ?? ""
        connectionID = saved?.connectionID ?? UUID().uuidString
        installationID = d.string(forKey: Keys.installation) ?? UUID().uuidString
        destinationID = d.string(forKey: Keys.destination) ?? UUID().uuidString
        gzip = d.bool(forKey: Keys.gzip)
        includeRoutes = d.bool(forKey: Keys.routes)
        onboardingDone = d.bool(forKey: Keys.onboarding)
        syncEnabled = d.bool(forKey: Keys.enabled)
        diagnosticsEnabled = d.bool(forKey: Keys.diagnostics)
        demoMode = d.bool(forKey: Keys.demo)
        enabledGroups = Set((d.stringArray(forKey: Keys.groups) ?? []).compactMap(DataGroup.init(rawValue:)))
        d.set(installationID, forKey: Keys.installation)
        refreshNamespace()
    }

    var endpointURL: URL? { Self.validURL(endpoint) }
    var connectionReady: Bool { endpointURL != nil && ConnectionPolicy.token(token) != nil }
    nonisolated static func validURL(_ value: String) -> URL? { ConnectionPolicy.url(value) }

    func saveConnection(endpoint value: String, token secret: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            guard secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SettingsError.invalidConnection }
            try Keychain.save(nil)
            credentialsLoaded = true
            endpoint = ""; token = ""; connectionID = UUID().uuidString
        } else {
            guard let url = ConnectionPolicy.url(value), let normalized = ConnectionPolicy.token(secret) else { throw SettingsError.invalidConnection }
            if url.absoluteString == endpoint && normalized == token { return }
            let next = SavedConnection(endpoint: url.absoluteString, token: normalized, connectionID: UUID().uuidString)
            try Keychain.save(next)
            credentialsLoaded = true
            endpoint = next.endpoint; token = next.token; connectionID = next.connectionID
        }
        changed(resetHistory: true)
    }

    /// Retry Keychain access after the first unlock; never overwrite unavailable credentials.
    func reloadCredentials() {
        guard let saved = try? Keychain.connection(),
              saved.endpoint != endpoint || saved.token != token || saved.connectionID != connectionID else { return }
        credentialsLoaded = true
        endpoint = saved.endpoint; token = saved.token; connectionID = saved.connectionID
        changed(resetHistory: true)
    }

    func requestHistoryReplay() throws {
        defaults.removeObject(forKey: Keys.namespaceSignature)
        changed(resetHistory: true)
        // Also recover an unreadable cursor file. This is an explicit full replay.
        try AnchorStore.shared.reset()
    }

    private func refreshNamespace() {
        // A boot before first unlock must not rotate an otherwise valid cursor.
        guard credentialsLoaded else { return }
        let signature = [connectionID, enabledGroups.map(\.rawValue).sorted().joined(separator: ","),
                         includeRoutes ? "routes" : "no-routes"].joined(separator: "|")
        if defaults.string(forKey: Keys.namespaceSignature) != signature {
            destinationID = UUID().uuidString
            defaults.set(destinationID, forKey: Keys.destination)
            defaults.set(signature, forKey: Keys.namespaceSignature)
            defaults.set(false, forKey: Keys.historyComplete)
        }
    }

    private func changed(resetHistory: Bool = false) {
        revision = UUID()
        if resetHistory { refreshNamespace() }
        let currentRevision = revision
        Task {
            await SyncCoordinator.shared.cancelStale(revision: currentRevision)
            await DiagShipper.shared.cancelStale(revision: currentRevision)
        }
    }

    func isCurrent(_ snapshot: SettingsSnapshot) -> Bool {
        syncEnabled && snapshot.syncEnabled && revision == snapshot.revision && destinationID == snapshot.destinationID
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(endpoint: endpointURL, token: token, gzip: gzip, includeRoutes: includeRoutes,
                         groups: enabledGroups, destinationID: destinationID, installationID: installationID,
                         revision: revision, syncEnabled: syncEnabled, diagnosticsEnabled: diagnosticsEnabled)
    }

    enum Keys {
        static let endpoint = "endpoint", token = "token", gzip = "gzip", routes = "includiPercorsi"
        static let onboarding = "onboardingCompletato", groups = "gruppiAttivi", demo = "modalitaDemo"
        static let characteristicsSent = "caratteristicheInviate", historyComplete = "storicoCompleto"
        static let enabled = "bridge.syncEnabled", diagnostics = "bridge.diagnosticsEnabled"
        static let installation = "bridge.installationID", destination = "bridge.destinationID"
        static let namespaceSignature = "bridge.namespaceSignature"
    }
}

struct SettingsSnapshot: Sendable {
    let endpoint: URL?
    let token: String
    let gzip: Bool
    let includeRoutes: Bool
    let groups: Set<DataGroup>
    var destinationID = UUID().uuidString
    var installationID = UUID().uuidString
    var revision = UUID()
    var syncEnabled = true
    var diagnosticsEnabled = false
}

enum Keychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "app.ezgna.healthbridge") + ".connection" }
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "connection-v2"]
    }
    static func save(_ connection: SavedConnection?) throws {
        guard let connection else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SettingsError.credentialsUnavailable }
            return
        }
        let data = try JSONEncoder().encode(connection)
        let values: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = base
            attributes.merge(values) { _, new in new }
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw SettingsError.credentialsUnavailable }
        } else if status != errSecSuccess { throw SettingsError.credentialsUnavailable }
    }
    static func connection() throws -> SavedConnection? {
        var query = base
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let saved = try? JSONDecoder().decode(SavedConnection.self, from: data),
              ConnectionPolicy.url(saved.endpoint) != nil, ConnectionPolicy.token(saved.token) == saved.token,
              UUID(uuidString: saved.connectionID) != nil else { throw SettingsError.credentialsUnavailable }
        return saved
    }
}
