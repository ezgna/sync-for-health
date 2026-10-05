import Foundation
import Observation
import Security

/// Impostazioni dell'utente (UserDefaults) — il token sta nel Portachiavi.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var endpoint: String { didSet { defaults.set(endpoint, forKey: Keys.endpoint) } }
    var gzip: Bool { didSet { defaults.set(gzip, forKey: Keys.gzip) } }
    var includeRoutes: Bool { didSet { defaults.set(includeRoutes, forKey: Keys.routes) } }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Keys.onboarding) } }
    /// Modalità dimostrativa: dati sintetici, nessuna lettura di Salute, nessun invio reale
    /// se non c'è un indirizzo. Pensata per provare l'app (e per la revisione di Apple).
    var demoMode: Bool {
        didSet {
            defaults.set(demoMode, forKey: Keys.demo)
            DemoMode.apply(demoMode)
        }
    }
    var enabledGroups: Set<DataGroup> {
        didSet { defaults.set(enabledGroups.map(\.rawValue).sorted(), forKey: Keys.groups) }
    }
    var token: String {
        didSet { Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.token) }
    }

    private init() {
        endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        gzip = defaults.bool(forKey: Keys.gzip)
        includeRoutes = defaults.bool(forKey: Keys.routes)
        onboardingDone = defaults.bool(forKey: Keys.onboarding)
        demoMode = defaults.bool(forKey: Keys.demo)
        if let raw = defaults.stringArray(forKey: Keys.groups) {
            enabledGroups = Set(raw.compactMap(DataGroup.init(rawValue:)))
        } else {
            // Nessun gruppo di serie: l'utente sceglie cosa condividere.
            enabledGroups = []
        }
        token = Keychain.get(Keys.token) ?? ""
    }

    var endpointURL: URL? { Self.validURL(endpoint) }

    /// Accetta https ovunque; http solo per indirizzi locali (test in LAN o sul Mac).
    nonisolated static func validURL(_ s: String) -> URL? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host(), !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", isLocal(host) { return url }
        return nil
    }

    nonisolated static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.")
            || host.hasPrefix("192.168.") || host.hasPrefix("10.") || isPrivate172(host)
    }

    /// 172.16.0.0/12 soltanto (172.16.x.x – 172.31.x.x).
    nonisolated static func isPrivate172(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts[0] == "172", let second = Int(parts[1]) else { return false }
        return (16...31).contains(second)
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(endpoint: endpointURL, token: token, gzip: gzip,
                         includeRoutes: includeRoutes, groups: enabledGroups)
    }

    enum Keys {
        static let endpoint = "endpoint"
        static let gzip = "gzip"
        static let routes = "includiPercorsi"
        static let onboarding = "onboardingCompletato"
        static let groups = "gruppiAttivi"
        static let token = "token"
        static let demo = "modalitaDemo"
        static let characteristicsSent = "caratteristicheInviate"
        /// Diventa vero al primo invio completato fino in fondo (storico tutto consegnato).
        static let historyComplete = "storicoCompleto"
    }
}

/// Copia immutabile delle impostazioni, da passare al motore di sincronizzazione.
struct SettingsSnapshot: Sendable {
    let endpoint: URL?
    let token: String
    let gzip: Bool
    let includeRoutes: Bool
    let groups: Set<DataGroup>
}

/// Accesso minimale al Portachiavi per il token.
enum Keychain {
    private static let service = "it.vcnngr.syncforhealth"

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Leggibile anche in background dopo il primo sblocco, mai sincronizzato su iCloud.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
