import SwiftUI
import UIKit

@main
struct SaluteLiberaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let settings = AppSettings.shared
    private let center = SyncCenter.shared
    private let log = SyncLog.shared
    private let today = TodayModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(center)
                .environment(log)
                .environment(today)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                DiagLog.info("app", "in background")
                center.setKeepAwake(false)
                BackgroundTasks.scheduleAll()
            case .active where settings.onboardingDone:
                DiagLog.info("app", "in primo piano")
                Task { await today.refresh() }
                // Riprende da solo (es. dopo un invio in pausa); se già in pari costa pochissimo.
                settings.reloadCredentials()
                if !settings.syncEnabled { break }
                if center.isSyncing { center.refreshKeepAwake() } else { center.syncNow(.automatico) }
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // I task in background vanno registrati prima della fine dell'avvio.
        BackgroundTasks.register()
        let reason = launchOptions?.keys.map(\.rawValue).sorted().joined(separator: ",") ?? "normale"
        DiagLog.info("app", "avvio v\(DiagLog.appVersion) (\(DiagLog.appBuild)), iOS \(DiagLog.iosVersion), \(Uploader.deviceModel), motivo: \(reason), dati protetti \(application.isProtectedDataAvailable ? "disponibili" : "NON disponibili")")
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            DiagLog.info("app", "dati protetti disponibili (iPhone sbloccato)")
            MainActor.assumeIsolated {
                // Salute torna leggibile: si riprende da dove ci si era fermati.
                AppSettings.shared.reloadCredentials()
                if AppSettings.shared.onboardingDone && AppSettings.shared.syncEnabled { SyncCenter.shared.syncNow(.automatico) }
            }
        }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
            DiagLog.info("app", "dati protetti in chiusura (iPhone in blocco)")
        }
        MainActor.assumeIsolated {
            if AppEnvironment.isDemo { SyncLog.shared.replaceForDemo(DemoData.records()) }
            let settings = AppSettings.shared
            let groups = settings.enabledGroups
            Task { await Health.logAuthorizationStatus(groups: groups) }
            // Gli osservatori HealthKit vanno riattivati a ogni avvio (anche in background).
            settings.reloadCredentials()
            if settings.onboardingDone && settings.syncEnabled {
                HealthBackground.start(groups: settings.enabledGroups)
            }
        }
        return true
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SyncCenter.self) private var center
    @State private var tab = AppEnvironment.initialTab ?? "oggi"
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingView()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            } else {
                TabView(selection: $tab) {
                    Tab("Oggi", systemImage: "heart.text.square.fill", value: "oggi") {
                        TodayView()
                    }
                    Tab("Invii", systemImage: "paperplane.fill", value: "invii") {
                        SendsView()
                    }
                    Tab("Impostazioni", systemImage: "gearshape.fill", value: "impostazioni") {
                        SettingsView()
                    }
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            showOnboarding = !settings.onboardingDone || AppEnvironment.forceOnboarding
            if AppEnvironment.autoSync { center.syncNow(.manuale) }
            if AppEnvironment.requestAuthOnLaunch {
                Task {
                    do {
                        let all = Set(DataGroup.allCases)
                        try await Health.requestAuthorization(groups: all, includeRoutes: true)
                        print("autorizzazione richiesta per \(HealthCatalog.readTypes(groups: all, includeRoutes: true).count) tipi")
                    } catch {
                        DiagLog.warning("permessi", DiagLog.describe(error))
                    }
                }
            }
        }
        .onChange(of: settings.onboardingDone) { _, done in
            withAnimation(.spring(duration: 0.6)) { showOnboarding = !done }
            if done {
                HealthBackground.start(groups: settings.enabledGroups)
                if settings.syncEnabled && settings.endpointURL != nil { center.syncNow(.manuale) }
            }
        }
    }
}
