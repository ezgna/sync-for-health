import SwiftUI

/// Introduzione al primo avvio: cosa fa, promessa di privacy, permessi, destinazione.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @State private var page = AppEnvironment.onboardingPage
    @State private var authorized = false
    @State private var authError: String?
    @State private var draftEndpoint = ""
    @State private var draftToken = ""
    @State private var isFinishing = false
    /// Gruppi scelti nell'introduzione: nessuno di serie.
    @State private var chosen: Set<DataGroup> = []
    @Environment(\.colorScheme) private var scheme

    private let pages = 4

    var body: some View {
        ZStack {
            OnboardingBackground(page: page)

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    privacy.tag(1)
                    permissions.tag(2)
                    destination.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(duration: 0.5), value: page)

                footer
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .allowsHitTesting(!isFinishing)
        .onAppear {
            draftEndpoint = settings.endpoint; draftToken = settings.token
            chosen = settings.enabledGroups
        }
        .onChange(of: chosen) { _, _ in authorized = false }
        .onChange(of: draftEndpoint) { _, value in
            if value != settings.endpoint { draftToken = "" }
        }
    }

    // MARK: Pagine

    private var welcome: some View {
        OnboardingPage {
            BrandMark(size: 132)
                .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
                .padding(.bottom, 18)
        } title: {
            Text(verbatim: AppInfo.name)
        } subtitle: {
            Text("I tuoi dati di Salute, sincronizzati in automatico con il server che scegli tu.")
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "arrow.triangle.2.circlepath", title: "Sempre in pari",
                        text: "iOSが実行を許可した際に差分を送ります。時刻や頻度は保証されません。")
                Feature(symbol: "square.stack.3d.up.fill", title: "Scegli tu cosa",
                        text: "Passi, battito, sonno, allenamenti, ECG e molto altro: attivi solo i gruppi che vuoi.")
                Feature(symbol: "gift.fill", title: "Gratuita, senza pubblicità",
                        text: "Nessun abbonamento, nessuna pubblicità, un formato JSON documentato.")
            }
        }
    }

    private var privacy: some View {
        OnboardingPage {
            ZStack {
                Circle().fill(.white.opacity(0.14)).frame(width: 132, height: 132)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 62, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.breathe, options: .repeat(.continuous))
            }
            .padding(.bottom, 18)
        } title: {
            Text("I tuoi dati vanno solo dove decidi tu")
        } subtitle: {
            Text("Nessun intermediario: dal tuo iPhone direttamente al tuo server.")
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "person.crop.circle.badge.xmark", title: "Nessun account",
                        text: "Nessuna registrazione, nessuna analisi, nessuna pubblicità, nessun SDK di terze parti, nessun iCloud.")
                Feature(symbol: "internaldrive.fill", title: "Niente copie",
                        text: "Sul telefono restano solo impostazioni e registro invii. I dati restano in Salute.")
                Feature(symbol: "key.fill", title: "Token al sicuro",
                        text: "La chiave del tuo server è custodita nel Portachiavi.")
            }
        }
    }

    private var permissions: some View {
        OnboardingPage {
            ZStack {
                Circle().fill(.white.opacity(0.14)).frame(width: 96, height: 96)
                Image(systemName: authorized ? "checkmark.seal.fill" : "heart.text.square.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: authorized)
            }
            .padding(.bottom, 14)
        } title: {
            Text("Scegli cosa condividere")
        } subtitle: {
            Text("Tocca i gruppi che vuoi sincronizzare: nessuno è scelto in partenza. Salute ti chiederà conferma voce per voce e potrai aggiungerne altri quando vuoi, da Impostazioni.")
        } content: {
            VStack(spacing: 10) {
                ForEach(DataGroup.allCases) { group in
                    GroupChoice(group: group, selected: chosen.contains(group)) {
                        if chosen.contains(group) { chosen.remove(group) } else { chosen.insert(group) }
                    }
                }
                Label("I percorsi GPS degli allenamenti restano spenti: puoi accenderli in Impostazioni.",
                      systemImage: "location.slash.fill")
                    .font(.footnote)
                    .opacity(0.85)
                    .padding(.top, 6)
                if let authError {
                    Text(authError).font(.footnote).opacity(0.85)
                }
            }
            .sensoryFeedback(.selection, trigger: chosen)
        }
    }

    private var destination: some View {
        OnboardingPage {
            ZStack {
                Circle().fill(.white.opacity(0.14)).frame(width: 132, height: 132)
                Image(systemName: "server.rack")
                    .font(.system(size: 54, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            .padding(.bottom, 18)
        } title: {
            Text("Dove inviare i dati")
        } subtitle: {
            Text("L'indirizzo HTTPS del tuo server. Riceverà un POST JSON a ogni novità.")
        } content: {
            VStack(spacing: 12) {
                GlassField(symbol: "link") {
                    TextField("", text: $draftEndpoint,
                              prompt: Text(verbatim: (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("it") ? "https://il-tuo-server.it/salute" : "https://your-server.example/health").foregroundStyle(.white.opacity(0.75)))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                GlassField(symbol: "key.fill") {
                    SecureField("", text: $draftToken,
                                prompt: Text("必須トークン").foregroundStyle(.white.opacity(0.75)))
                }
                ConnectionTestRow(endpoint: draftEndpoint, token: draftToken, gzip: settings.gzip, onGlass: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .glassEffect(.clear.tint(.black.opacity(0.10)).interactive(), in: .rect(cornerRadius: 18))
                if let authError { Text(authError).font(.footnote) }
                Text("Puoi lasciarlo vuoto e configurarlo più tardi nelle Impostazioni.")
                    .font(.footnote)
                    .opacity(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                Button {
                    settings.demoMode = true
                    settings.syncEnabled = true
                    withAnimation(.spring(duration: 0.6)) { settings.onboardingDone = true }
                } label: {
                    Label("Non hai un server? Prova con dati di esempio", systemImage: "sparkles")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.tint(.white.opacity(0.10)).interactive(), in: .capsule)
                .padding(.top, 6)
            }
        }
    }

    // MARK: Piede di pagina

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(i == page ? 1 : 0.4))
                        .frame(width: i == page ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.4), value: page)
            .accessibilityHidden(true)

            Button(action: advance) {
                Text(buttonTitle)
                    .font(.headline)
                    .foregroundStyle(Palette.brand[1])
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentTransition(.interpolate)
            }
            .disabled(isFinishing)
            .buttonStyle(.glassProminent)
            .tint(.white)
            .sensoryFeedback(.selection, trigger: page)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var buttonTitle: LocalizedStringKey {
        switch page {
        case 2:
            if authorized { "Continua" }
            else if chosen.isEmpty { "Salta per ora" }
            else { "Consenti accesso a Salute" }
        case 3: AppSettings.validURL(draftEndpoint) == nil ? "Configura più tardi" : "Inizia"
        default: "Continua"
        }
    }

    private func advance() {
        guard !isFinishing else { return }
        switch page {
        case 2:
            settings.enabledGroups = chosen
            guard !chosen.isEmpty && !authorized else { page = 3; return }
            isFinishing = true
            Task {
                defer { isFinishing = false }
                do {
                    try await Health.requestAuthorization(groups: chosen, includeRoutes: settings.includeRoutes)
                    authError = nil
                    authorized = true
                    page = 3
                } catch { authError = "ヘルスケアの権限を確認できませんでした。ロック解除後に再試行してください。" }
            }
        case pages - 1:
            // TabView can reach this page by swiping; apply the final selection,
            // including an empty selection, and request permission here as well.
            let groups = chosen, address = draftEndpoint, secret = draftToken
            isFinishing = true
            Task {
                defer { isFinishing = false }
                do {
                    settings.enabledGroups = groups
                    if !groups.isEmpty && !authorized {
                        try await Health.requestAuthorization(groups: groups, includeRoutes: settings.includeRoutes)
                        authorized = true
                    }
                    try settings.saveConnection(endpoint: address, token: secret)
                    settings.syncEnabled = settings.connectionReady
                    authError = nil
                    withAnimation(.spring(duration: 0.6)) { settings.onboardingDone = true }
                } catch { authError = error.localizedDescription }
            }
        default:
            page += 1
        }
    }

}

// MARK: - Componenti

/// Un gruppo di dati da scegliere: icona, nome, cosa contiene, quanti tipi.
private struct GroupChoice: View {
    let group: DataGroup
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: group.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.title).font(.subheadline.weight(.semibold))
                        Text(verbatim: "\(HealthCatalog.count(in: group))")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.white.opacity(0.18), in: .capsule)
                    }
                    Text(group.detail)
                        .font(.caption)
                        .opacity(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.tint(.white.opacity(selected ? 0.26 : 0.08)).interactive(), in: .rect(cornerRadius: 16))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OnboardingPage<Hero: View, Title: View, Subtitle: View, Content: View>: View {
    @ViewBuilder var hero: Hero
    @ViewBuilder var title: Title
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                title
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                subtitle
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .opacity(0.88)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
                content
                    .padding(.top, 30)
            }
            .padding(.horizontal, 28)
            .padding(.top, 56)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }
}

private struct Feature: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 44, height: 44)
                .glassEffect(.clear.tint(.white.opacity(0.12)), in: .rect(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GlassField<Field: View>: View {
    let symbol: String
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .opacity(0.9)
            field
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .glassEffect(.clear.tint(.black.opacity(0.10)).interactive(), in: .rect(cornerRadius: 18))
    }
}

/// Gradiente vivo che si muove piano e cambia tono con la pagina.
private struct OnboardingBackground: View {
    let page: Int
    @Environment(\.colorScheme) private var scheme

    private var palette: [Color] {
        let light: [[UInt32]] = [
            [0xFF7A59, 0xF2366F, 0x9B2FD9],
            [0x6D5BF5, 0x9B2FD9, 0xF2366F],
            [0xF2366F, 0xFF7A59, 0x9B2FD9],
            [0x3B82F6, 0x7C3AED, 0xF2366F],
        ]
        let dark: [[UInt32]] = [
            [0x8A2F3C, 0x7A1747, 0x3D1470],
            [0x2E2378, 0x4C1670, 0x6E1843],
            [0x7A1747, 0x8A3A2A, 0x3D1470],
            [0x1E3A8A, 0x3D1470, 0x6E1843],
        ]
        let set = (scheme == .dark ? dark : light)[min(page, 3)]
        return set.map { Color(hex: $0) }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let a = Float(sin(t * 0.35) * 0.12)
            let b = Float(cos(t * 0.27) * 0.12)
            let c = palette
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + a, 0], [1, 0],
                    [0, 0.5 + b], [0.5 + b, 0.5 - a], [1, 0.5 - b],
                    [0, 1], [0.5 - a, 1], [1, 1],
                ],
                colors: [
                    c[0], c[1], c[1],
                    c[1], c[0], c[2],
                    c[2], c[2], c[1],
                ])
        }
        .overlay(Color.black.opacity(scheme == .dark ? 0.15 : 0.06))
        .animation(.easeInOut(duration: 0.8), value: page)
        .ignoresSafeArea()
    }
}
