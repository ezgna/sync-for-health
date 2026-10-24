import Foundation

/// Opzioni di avvio. Gli argomenti di avvio esistono SOLO nelle build DEBUG; la modalità
/// dimostrativa invece si accende anche in Release, da Impostazioni o dall'introduzione.
enum AppEnvironment {
    /// Dati di esempio al posto di Salute: interruttore dell'utente oppure `-demo` (solo DEBUG).
    static var isDemo: Bool { launchDemo || UserDefaults.standard.bool(forKey: AppSettings.Keys.demo) }

    #if DEBUG
    /// `-demo`: dati di esempio (simulatore e screenshot), senza etichetta «Dati di esempio».
    static let launchDemo = ProcessInfo.processInfo.arguments.contains("-demo")
    /// `-onboarding`: mostra sempre l'introduzione.
    static let forceOnboarding = ProcessInfo.processInfo.arguments.contains("-onboarding")
    /// `-autoSync`: avvia un invio appena l'app è pronta.
    static let autoSync = ProcessInfo.processInfo.arguments.contains("-autoSync")
    /// `-tab invii|impostazioni|oggi`
    static let initialTab = UserDefaults.standard.string(forKey: "tab")
    /// `-pagina N`: pagina iniziale dell'introduzione.
    static let onboardingPage = UserDefaults.standard.integer(forKey: "pagina")
    /// `-fondo`: apre le schermate scorse fino in fondo (per gli screenshot).
    static let scrollToBottom = ProcessInfo.processInfo.arguments.contains("-fondo")
    /// `-chiediPermessi`: chiede subito l'autorizzazione di Salute per tutti i gruppi (verifica del catalogo).
    static let requestAuthOnLaunch = ProcessInfo.processInfo.arguments.contains("-chiediPermessi")
    /// `-diagnostica`: apre direttamente Impostazioni › Diagnostica.
    static let openDiagnostics = ProcessInfo.processInfo.arguments.contains("-diagnostica")
    #else
    static let launchDemo = false
    static let forceOnboarding = false
    static let autoSync = false
    static let initialTab: String? = nil
    static let onboardingPage = 0
    static let scrollToBottom = false
    static let requestAuthOnLaunch = false
    static let openDiagnostics = false
    #endif
}

/// Nome dell'app come appare sotto l'icona (CFBundleDisplayName localizzato).
enum AppInfo {
    static var name: String {
        Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "HealthBridge"
    }
    /// Informativa sulla privacy e pagina di supporto (sito statico).
    static let privacyURL = URL(string: "https://github.com/ezgna/sync-for-health/blob/main/docs/HEALTHBRIDGE.md")!
    static let supportURL = URL(string: "https://github.com/ezgna/sync-for-health")!
    /// Codice sorgente pubblico (licenza MIT).
    static let sourceURL = URL(string: "https://github.com/ezgna/sync-for-health")!
}
