import SwiftUI

/// Stato della sincronizzazione: anello animato, frase gentile, pulsante.
struct SyncHero: View {
    @Environment(SyncCenter.self) private var center
    @Environment(SyncLog.self) private var log
    @Environment(AppSettings.self) private var settings

    private enum Mood { case ok, syncing, error, setup, waiting, paused, locked }

    private var mood: Mood {
        if center.isSyncing { return .syncing }
        if settings.endpointURL == nil && !(settings.demoMode || AppEnvironment.launchDemo) { return .setup }
        switch center.phase {
        case .failure: return .error
        case .paused: return .paused
        case .waitingUnlock: return .locked
        default: break
        }
        if log.lastSuccess == nil { return .waiting }
        return .ok
    }

    private var colors: [Color] {
        switch mood {
        case .ok, .syncing, .waiting: Palette.brand
        case .error: [Palette.warning, Palette.failure]
        case .paused: [Palette.warning, Palette.body[1]]
        case .setup, .locked: [Color.secondary, Color.secondary.opacity(0.6)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                StatusRing(mood: ringMood, colors: colors)
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if mood == .syncing {
                SyncProgressPanel(progress: center.progress, keepingAwake: center.keepingAwake)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(alignment: .top, spacing: 0) {
                stat(value: Format.integer(log.samplesToday + (center.isSyncing ? center.progress.samplesSent : 0)),
                     label: "campioni oggi")
                Divider().frame(height: 34).padding(.horizontal, 14)
                stat(value: Format.integer(log.records.filter { Calendar.current.isDateInToday($0.date) }.count),
                     label: "invii oggi")
                Divider().frame(height: 34).padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: settings.endpointURL?.scheme == "https" ? "lock.fill" : "network")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.brand[1])
                        Text(settings.endpointURL?.host() ?? "—")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(height: 25)
                    Text("destinazione")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                center.syncNow()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: center.isSyncing)
                    if center.isSyncing {
                        Text("Invio in corso…")
                    } else if mood == .error || mood == .paused {
                        Text("Riprendi ora")
                    } else {
                        Text("Sincronizza ora")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.brand[1])
            .disabled(center.isSyncing)
            .sensoryFeedback(.impact(weight: .light), trigger: center.isSyncing) { _, new in new }
        }
        .padding(20)
        .glassEffect(.regular.tint(colors[0].opacity(0.06)), in: .rect(cornerRadius: 30))
        .sensoryFeedback(.success, trigger: center.successTick)
        .sensoryFeedback(.error, trigger: center.failureTick)
        .animation(.spring(duration: 0.5), value: center.phase)
    }

    private var ringMood: StatusRing.Mood {
        switch mood {
        case .ok: .ok
        case .syncing: .syncing
        case .error: .error
        case .setup: .setup
        case .waiting: .waiting
        case .paused: .paused
        case .locked: .locked
        }
    }

    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: LocalizedStringKey {
        switch mood {
        case .ok: "Tutto sincronizzato"
        case .syncing: "Sincronizzazione…"
        case .error: "Qualcosa non è andato"
        case .setup: "Manca la destinazione"
        case .waiting: "Pronto a partire"
        case .paused: "In pausa"
        case .locked: "In attesa dello sblocco"
        }
    }

    private var subtitle: String {
        switch mood {
        case .syncing:
            return center.progress.samplesSent > 0
                ? String(localized: "Sto inviando i tuoi dati al server")
                : String(localized: "Sto leggendo i dati da Salute")
        case .paused:
            let sent = log.records.first.map { Format.integer($0.samples + $0.deleted) } ?? "0"
            if case .paused(let m) = center.phase, !m.isEmpty {
                return String(localized: "\(sent) campioni inviati. \(m)")
            }
            return String(localized: "\(sent) campioni inviati. Riprende da solo.")
        case .locked:
            return String(localized: "Salute si può leggere solo con l'iPhone sbloccato. Riprendo da solo appena lo sblocchi.")
        case .setup:
            return String(localized: "Aggiungi l'indirizzo del tuo server nelle Impostazioni.")
        case .error:
            if case .failure(let m) = center.phase, !m.isEmpty {
                return String(localized: "Riproverò da solo. \(m)")
            }
            return String(localized: "Riproverò da solo tra poco.")
        case .waiting:
            return String(localized: "Il primo invio porterà con sé tutto lo storico.")
        case .ok:
            if let last = log.lastSuccess?.date {
                let rel = last.formatted(.relative(presentation: .named))
                return String(localized: "Ultimo invio \(rel)")
            }
            return ""
        }
    }
}

/// L'anello: pieno e fermo quando va tutto bene, gira durante l'invio.
struct StatusRing: View {
    enum Mood { case ok, syncing, error, setup, waiting, paused, locked }
    let mood: Mood
    let colors: [Color]
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(colors[0].opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: mood == .syncing ? 0.32 : (mood == .setup || mood == .locked ? 0 : (mood == .paused ? 0.75 : 1)))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .animation(mood == .syncing
                           ? .linear(duration: 1.1).repeatForever(autoreverses: false)
                           : .spring(duration: 0.6), value: spin)
            if mood == .ok || mood == .waiting {
                Circle()
                    .fill(LinearGradient.diagonal(colors).opacity(0.18))
                    .padding(13)
                    .blur(radius: 6)
            }
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(LinearGradient.diagonal(colors))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: mood == .syncing)
        }
        .onChange(of: mood == .syncing, initial: true) { _, syncing in spin = syncing }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch mood {
        case .ok: "checkmark"
        case .syncing: "arrow.up"
        case .error: "exclamationmark"
        case .setup: "link"
        case .waiting: "arrow.up.heart.fill"
        case .paused: "pause.fill"
        case .locked: "lock.fill"
        }
    }
}

/// Avanzamento di un invio: tipo N di M, campioni e blocchi inviati, consiglio per lo storico.
struct SyncProgressPanel: View {
    let progress: SyncProgress
    let keepingAwake: Bool

    private var fraction: Double {
        guard progress.typeCount > 0 else { return 0 }
        return Double(max(progress.typeIndex - 1, 0)) / Double(progress.typeCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: fraction)
                .tint(LinearGradient(colors: Palette.brand, startPoint: .leading, endPoint: .trailing))
                .animation(.easeInOut, value: fraction)
            if progress.typeCount > 0 {
                HStack(spacing: 6) {
                    Text("Tipo \(progress.typeIndex) di \(progress.typeCount)")
                        .monospacedDigit()
                    if let name = progress.typeName {
                        Text("·").foregroundStyle(.tertiary)
                        Text(verbatim: name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            Text("\(Format.integer(progress.samplesSent)) campioni inviati · \(Format.integer(progress.blocksSent)) blocchi")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if keepingAwake {
                Label {
                    Text("Tieni l'app aperta: l'iPhone resta acceso finché lo storico non è stato inviato.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sun.max.fill")
                        .symbolEffect(.pulse, options: .repeat(.continuous))
                }
                .font(.footnote)
                .foregroundStyle(Palette.warning)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.warning.opacity(0.12), in: .rect(cornerRadius: 12))
            }
        }
    }
}
