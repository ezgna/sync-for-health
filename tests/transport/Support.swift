// Synthetic standalone dependencies. No app settings, Keychain or HealthKit access.
import Foundation

enum Storage { static func excludeFromBackup(_ url: inout URL) {} }
struct SettingsSnapshot: Sendable {
    let endpoint: URL?
    let token: String
    let gzip: Bool
    let syncEnabled: Bool
    let diagnosticsEnabled: Bool
    let installationID: String
    let destinationID: String
    let revision: UUID
}
@MainActor final class AppSettings {
    static let shared = AppSettings()
    var syncEnabled = true
    var diagnosticsEnabled = false
    let revision = UUID()
    var snapshot: SettingsSnapshot {
        SettingsSnapshot(endpoint: nil, token: "synthetic-only", gzip: false,
                         syncEnabled: syncEnabled, diagnosticsEnabled: diagnosticsEnabled,
                         installationID: UUID().uuidString, destinationID: UUID().uuidString, revision: revision)
    }
    func isCurrent(_ snapshot: SettingsSnapshot) -> Bool { true }
}

enum AppEnvironment { static let isDemo = false }
