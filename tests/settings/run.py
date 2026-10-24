#!/usr/bin/env python3
"""Compile the production settings model with isolated defaults and an in-memory Keychain adapter.
Never touches the real Keychain, HealthKit, user defaults domain, or network.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root/'SaluteLibera/Model/Settings.swift').read_text()
source = source[:source.index('\nenum Keychain {')]
source = source.replace('import Security\n', '').replace('UserDefaults.standard', 'TestDefaults.shared')
source = source.replace('private init() {', 'init() {')
stubs = r'''
enum DataGroup: String, CaseIterable, Sendable { case body, heart }
enum DemoMode { @MainActor static func apply(_ on: Bool) {} }
actor SyncCoordinator {
    static let shared = SyncCoordinator()
    func cancelStale(revision: UUID) {}
}
actor DiagShipper {
    static let shared = DiagShipper()
    func cancelStale(revision: UUID) {}
}
@MainActor enum Keychain {
    static var saved: SavedConnection?
    static var fail = false
    static var writes = 0
    static func save(_ value: SavedConnection?) throws {
        if fail { throw SettingsError.credentialsUnavailable }
        saved = value; writes += 1
    }
    static func connection() throws -> SavedConnection? {
        if fail { throw SettingsError.credentialsUnavailable }
        return saved
    }
}
final class AnchorStore: @unchecked Sendable {
    static let shared = AnchorStore()
    var resets = 0
    func reset() throws { resets += 1 }
}
enum TestDefaults {
    nonisolated(unsafe) static let shared = UserDefaults(suiteName: "HealthBridgeSettingsTest." + UUID().uuidString)!
}
'''
tests = r'''
@main struct SettingsContractTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); count += 1
        }
        let tokenA = String(repeating: "a", count: 64)
        let tokenB = String(repeating: "b", count: 64)
        check(ConnectionPolicy.url("http://127.0.0.1/ingest") == nil, "HTTPS only")
        check(ConnectionPolicy.url("https://u:p@example.invalid/ingest") == nil, "No credentials")
        check(ConnectionPolicy.url("https://example.invalid/ingest?t=secret") == nil, "No query token")
        check(ConnectionPolicy.url("https://example.invalid/ingest#x") == nil, "No fragment")
        check(ConnectionPolicy.url(" HTTPS://EXAMPLE.invalid:443/ingest \n")?.absoluteString == "https://example.invalid/ingest", "Canonical URL")
        check(ConnectionPolicy.token(" \n" + tokenA + "\n") == tokenA, "Trim paste whitespace")
        check(ConnectionPolicy.token("x\ny" + tokenA) == nil, "No embedded CRLF")
        check(ConnectionPolicy.token("a b" + tokenA) == nil, "No embedded space")
        check(ConnectionPolicy.token("short") == nil, "Token minimum")
        let settings = AppSettings()
        check(!settings.syncEnabled && !settings.diagnosticsEnabled, "Explicit opt-in defaults")
        let initial = settings.destinationID
        try settings.saveConnection(endpoint: "https://one.invalid/ingest", token: tokenA)
        check(Keychain.saved?.endpoint == settings.endpoint && Keychain.saved?.token == settings.token, "URL and token paired")
        check(initial != settings.destinationID, "Connection resets cursor namespace")
        check(!settings.isCurrent(settings.snapshot), "Paused snapshot invalid")
        settings.syncEnabled = true
        let first = settings.snapshot
        check(settings.isCurrent(first), "Enabled current snapshot")
        let namespace = settings.destinationID
        try settings.saveConnection(endpoint: "https://one.invalid/ingest", token: " " + tokenA + " ")
        check(settings.destinationID == namespace && settings.isCurrent(first), "Equivalent connection no reset")
        settings.gzip.toggle()
        check(settings.destinationID == namespace && !settings.isCurrent(first), "Transport change cancels without replay")
        let current = settings.snapshot
        Keychain.fail = true
        do {
            try settings.saveConnection(endpoint: "https://two.invalid/ingest", token: tokenB)
            preconditionFailure("Expected secure-save failure")
        } catch {}
        check(settings.endpoint == "https://one.invalid/ingest" && settings.token == tokenA, "Save failure leaves active pair")
        check(settings.isCurrent(current), "Save failure preserves revision")
        Keychain.fail = false
        try settings.saveConnection(endpoint: "https://two.invalid/ingest", token: tokenB)
        check(settings.destinationID != namespace && !settings.isCurrent(current), "New host cannot inherit cursor")
        let connectionScope = settings.destinationID
        settings.enabledGroups.insert(.heart)
        check(settings.destinationID != connectionScope, "New group backfills")
        let groupScope = settings.destinationID
        settings.includeRoutes = true
        check(settings.destinationID != groupScope, "Routes ON backfills")
        let routeScope = settings.destinationID
        let restarted = AppSettings()
        check(restarted.destinationID == routeScope && restarted.installationID == settings.installationID, "Restart retains matching scope")
        check(restarted.endpoint == settings.endpoint && restarted.token == settings.token, "Restart restores atomic pair")
        Keychain.fail = true
        let lockedBoot = AppSettings()
        check(lockedBoot.destinationID == routeScope && !lockedBoot.connectionReady, "Locked boot preserves cursor while credentials unavailable")
        Keychain.fail = false
        lockedBoot.reloadCredentials()
        check(lockedBoot.destinationID == routeScope && lockedBoot.connectionReady, "First unlock restores same destination without full replay")
        let beforePause = settings.snapshot
        settings.syncEnabled = false
        check(!settings.isCurrent(beforePause), "Pause invalidates in-flight snapshot")
        try settings.requestHistoryReplay()
        check(settings.destinationID != routeScope && AnchorStore.shared.resets == 1, "Full replay recovers cursor file")
        try settings.saveConnection(endpoint: "", token: "")
        check(Keychain.saved == nil && !settings.connectionReady, "Explicit connection removal")
        Keychain.saved = SavedConnection(endpoint: "https://restored.invalid/ingest", token: tokenA, connectionID: UUID().uuidString)
        settings.reloadCredentials()
        check(settings.connectionReady && settings.endpoint == "https://restored.invalid/ingest", "First-unlock reload")
        print("Settings contract: \(count) checks passed (isolated defaults, mock Keychain)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='healthbridge-settings-') as directory:
    path = Path(directory)
    (path/'SettingsTests.swift').write_text(source + stubs + tests)
    subprocess.run(['swiftc','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-parse-as-library',str(path/'SettingsTests.swift'),'-o',str(path/'settings-tests')],check=True)
    subprocess.run([str(path/'settings-tests')],check=True)
