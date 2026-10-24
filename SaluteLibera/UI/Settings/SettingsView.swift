import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SyncCenter.self) private var center
    @State private var draftEndpoint = ""
    @State private var draftToken = ""
    @State private var connectionMessage: String?
    @State private var confirmReset = false
    @State private var authMessage: LocalizedStringKey?
    @State private var showDiagnostics = AppEnvironment.openDiagnostics

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    LabeledField(symbol: "link", title: "Indirizzo") {
                        TextField(text: $draftEndpoint, prompt: Text(verbatim: (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("it") ? "https://il-tuo-server.it/salute" : "https://your-server.example/health")) {
                            Text("Indirizzo")
                        }
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledField(symbol: "key.fill", title: "Token") {
                        SecureField("必須トークン", text: $draftToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    ConnectionTestRow(endpoint: draftEndpoint, token: draftToken, gzip: settings.gzip)
                    Button("接続設定を保存") {
                        do {
                            try settings.saveConnection(endpoint: draftEndpoint, token: draftToken)
                            draftEndpoint = settings.endpoint
                            draftToken = settings.token
                            connectionMessage = "保存しました。送信先が変わった場合は履歴を最初から再送します。"
                        } catch { connectionMessage = error.localizedDescription }
                    }
                    if let connectionMessage { Text(connectionMessage).font(.footnote) }
                } header: {
                    Text("Destinazione")
                } footer: {
                    Text("URLとトークンは保存ボタンで一緒に確定し、キーチェーンへ保存します。送信先URLを変更したら、新しいトークンを入力してください。")
                }

                Section {
                    Toggle("同期を有効にする", isOn: $settings.syncEnabled)
                        .disabled(!settings.connectionReady && !settings.demoMode)
                } footer: {
                    Text("OFFにすると実行中の送信と自動同期を停止します。Mac停止中の未送信分は、接続できた次回に再試行します。")
                }

                Section {
                    Toggle(isOn: $settings.gzip) {
                        SettingRow(symbol: "archivebox.fill", colors: Palette.other, title: "Comprimi con gzip")
                    }
                } footer: {
                    Text("Riduce i dati inviati. Attivalo solo se il tuo server accetta «Content-Encoding: gzip».")
                }

                Section {
                    ForEach(DataGroup.allCases) { group in
                        Toggle(isOn: binding(for: group)) {
                            SettingRow(symbol: group.symbol, colors: Palette.group(group),
                                       title: group.title, detail: group.detail,
                                       badge: HealthCatalog.count(in: group))
                        }
                    }
                } header: {
                    Text("Dati da sincronizzare")
                } footer: {
                    Text("Accendi un gruppo per aggiungerlo: Salute ti chiederà il permesso solo per i tipi nuovi. Il numero indica quanti tipi contiene ogni gruppo; partono solo quelli che hai autorizzato in Salute.")
                }

                Section {
                    Toggle(isOn: $settings.includeRoutes) {
                        SettingRow(symbol: "map.fill", colors: Palette.activity, title: "Percorsi GPS degli allenamenti")
                    }
                    .disabled(!settings.enabledGroups.contains(.allenamenti))
                    .onChange(of: settings.includeRoutes) { _, on in
                        if on { requestAuthorization() }
                    }
                } footer: {
                    Text("Spento di serie: i percorsi rivelano dove vivi e ti alleni. Richiede il gruppo Allenamenti.")
                }

                Section {
                    Button(action: requestAuthorization) {
                        SettingRow(symbol: "heart.text.square.fill", colors: Palette.heart, title: "Rivedi i permessi di Salute")
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    if let authMessage {
                        Text(authMessage)
                    } else {
                        Text("Per togliere un permesso: Impostazioni › App › Salute › Accesso ai dati › \(AppInfo.name).")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        SettingRow(symbol: "clock.arrow.circlepath", colors: [Palette.warning, Palette.failure],
                                   title: "Invia di nuovo tutto lo storico")
                    }
                    .foregroundStyle(Palette.failure)
                    .disabled(center.isSyncing)
                } header: {
                    Text("Storico")
                } footer: {
                    Text("Utile se il server ha perso i dati. Il prossimo invio ripartirà dal primo campione mai registrato.")
                }

                Section {
                    Toggle(isOn: $settings.demoMode) {
                        SettingRow(symbol: "sparkles", colors: Palette.brand, title: "Modalità dimostrativa",
                                   detail: "Dati di esempio inventati, Salute non viene letta")
                    }
                } footer: {
                    Text("デモはiPhone内だけで動きます。合成データをサーバーへ送信しません。")
                }

                Section {
                    Toggle("診断ログをMacへ送信", isOn: $settings.diagnosticsEnabled)
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        SettingRow(symbol: "stethoscope", colors: Palette.hearing, title: "Diagnostica",
                                   detail: "Registro tecnico, senza valori di salute")
                    }
                }

                Section {
                    InfoRow(symbol: "lock.shield.fill", text: "Nessun account, nessuna analisi, nessuna pubblicità, nessun SDK di terze parti, nessun iCloud.")
                    InfoRow(symbol: "internaldrive.fill", text: "Sul telefono restano solo impostazioni, segnalibri di sincronizzazione e registro invii.")
                    Link(destination: AppInfo.privacyURL) {
                        Label("Informativa sulla privacy", systemImage: "hand.raised.fill")
                    }
                    Link(destination: AppInfo.supportURL) {
                        Label("Assistenza", systemImage: "questionmark.circle.fill")
                    }
                    Link(destination: AppInfo.sourceURL) {
                        Label("Codice sorgente (licenza MIT)", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    LabeledContent("Versione", value: "\(Uploader.appVersion) · protocollo v2")
                } header: {
                    Text("Informazioni")
                } footer: {
                    VStack(spacing: 10) {
                        BrandMark(size: 34, fill: AnyShapeStyle(LinearGradient.diagonal(Palette.brand)), animated: false)
                        Text(verbatim: AppInfo.name)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .id("fine")
                }
            }
            .task {
                guard AppEnvironment.scrollToBottom else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo("fine", anchor: .bottom)
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Impostazioni")
            .navigationDestination(isPresented: $showDiagnostics) { DiagnosticsView() }
            .confirmationDialog("Inviare di nuovo tutto lo storico?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Invia tutto lo storico", role: .destructive) {
                    do {
                        try settings.requestHistoryReplay()
                        Task { await SyncCoordinator.shared.request(.storico) }
                    } catch { connectionMessage = "同期位置を初期化できませんでした。空き容量と端末のロック状態を確認してください。" }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Tutti i dati autorizzati verranno reinviati dall'inizio. Il server riceverà dei duplicati: gli uuid permettono di riconoscerli.")
            }
            .onAppear {
                settings.reloadCredentials()
                draftEndpoint = settings.endpoint
                draftToken = settings.token
            }
            .onChange(of: draftEndpoint) { _, value in
                if value != settings.endpoint { draftToken = "" }
                connectionMessage = nil
            }
            .onChange(of: settings.enabledGroups) { _, groups in
                HealthBackground.restart(groups: groups)
            }
            .onChange(of: settings.includeRoutes) { _, _ in
                HealthBackground.restart(groups: settings.enabledGroups)
            }
            .onChange(of: settings.syncEnabled) { _, on in
                if on {
                    HealthBackground.start(groups: settings.enabledGroups)
                    center.syncNow(.manuale)
                } else { HealthBackground.stop() }
            }
            .onChange(of: settings.demoMode) { _, _ in
                HealthBackground.restart(groups: settings.enabledGroups)
            }
            }
        }
    }

    private func binding(for group: DataGroup) -> Binding<Bool> {
        Binding {
            settings.enabledGroups.contains(group)
        } set: { on in
            if on {
                settings.enabledGroups.insert(group)
                requestAuthorization(for: [group])
            } else {
                settings.enabledGroups.remove(group)
            }
        }
    }

    private func requestAuthorization() {
        requestAuthorization(for: settings.enabledGroups)
    }

    private func requestAuthorization(for groups: Set<DataGroup>) {
        guard !settings.demoMode else { return }
        guard !groups.isEmpty else {
            authMessage = "Accendi almeno un gruppo qui sopra."
            return
        }
        Task {
            do {
                try await Health.requestAuthorization(groups: groups, includeRoutes: settings.includeRoutes)
                try settings.requestHistoryReplay()
                if settings.syncEnabled { center.syncNow(.manuale) }
                authMessage = "権限の確認が終わりました。次回は許可された履歴を再走査します。HealthKitは読取許可の有無をアプリへ公開しません。"
            } catch {
                authMessage = "Impossibile chiedere i permessi: \(error.localizedDescription)"
            }
        }
    }
}

/// Riga con icona arrotondata, titolo, dettaglio e contatore.
struct SettingRow: View {
    let symbol: String
    let colors: [Color]
    let title: LocalizedStringResource
    var detail: LocalizedStringResource? = nil
    var badge: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            GroupIcon(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let badge {
                Spacer(minLength: 4)
                Text("\(badge)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: .capsule)
            }
        }
    }
}

struct LabeledField<Field: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.brand[1])
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                field
            }
        }
        .padding(.vertical, 2)
    }
}

struct InfoRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(LinearGradient.diagonal(Palette.brand))
        }
    }
}

/// "Prova connessione" con esito in linea.
struct ConnectionTestRow: View {
    let endpoint: String
    let token: String
    let gzip: Bool
    var onGlass = false

    private enum TestState: Equatable { case idle, running, ok(Int), failed(String) }
    @State private var state: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        Button {
            state = .running
            let current = UUID()
            generation = current
            let address = endpoint, secret = token, compressed = gzip
            testTask = Task {
                let result = await ConnectionTest.run(endpoint: address, token: secret, gzip: compressed)
                guard !Task.isCancelled, generation == current else { return }
                switch result {
                case .success(let bytes): state = .ok(bytes)
                case .failure(let e): state = .failed(e.localizedDescription)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    switch state {
                    case .running: ProgressView().controlSize(.small)
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.failure)
                    case .idle: Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prova connessione")
                        .fontWeight(.semibold)
                    switch state {
                    case .ok:
                        Text("Il server ha risposto: tutto a posto.")
                            .font(.caption)
                            .foregroundStyle(onGlass ? .white.opacity(0.85) : .secondary)
                    case .failed(let message):
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(onGlass ? .white.opacity(0.85) : Palette.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    default:
                        EmptyView()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(state == .running || endpoint.isEmpty)
        .sensoryFeedback(trigger: state) { _, new in
            switch new {
            case .ok: .success
            case .failed: .error
            default: nil
            }
        }
        .onChange(of: endpoint) { resetTest() }
        .onChange(of: token) { resetTest() }
        .onChange(of: gzip) { resetTest() }
        .onDisappear { resetTest() }
    }

    private func resetTest() {
        generation = UUID()
        testTask?.cancel()
        testTask = nil
        state = .idle
    }

}
