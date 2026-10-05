import SwiftUI

/// Registro tecnico: consultazione, esportazione e spedizione al server.
/// Contiene solo conteggi, tipi, esiti ed errori — mai valori di salute.
struct DiagnosticsView: View {
    @State private var lines: [String] = []
    @State private var sending = false
    @State private var sendResult: SendResult?
    @State private var size = 0

    private enum SendResult: Equatable { case ok, failed(String) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    LabeledContent("Dimensione", value: Format.bytes(size))
                    LabeledContent("Righe mostrate", value: Format.integer(lines.count))
                    if let last = UserDefaults.standard.object(forKey: "diagnosticaUltimoInvio") as? Date {
                        LabeledContent("Ultimo invio al server", value: last.formatted(.relative(presentation: .named)))
                    }
                    Button {
                        Task { await send() }
                    } label: {
                        HStack(spacing: 10) {
                            Group {
                                if sending {
                                    ProgressView().controlSize(.small)
                                } else {
                                    switch sendResult {
                                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.failure)
                                    case nil: Image(systemName: "paperplane.fill")
                                    }
                                }
                            }
                            .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Invia diagnostica ora").fontWeight(.semibold)
                                switch sendResult {
                                case .ok:
                                    Text("Inviata al tuo server.").font(.caption).foregroundStyle(.secondary)
                                case .failed(let m):
                                    Text(m).font(.caption).foregroundStyle(Palette.failure)
                                case nil:
                                    EmptyView()
                                }
                            }
                        }
                    }
                    .disabled(sending)
                    ShareLink(item: DiagLog.fileURL) {
                        Label("Esporta il registro", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Il registro contiene solo eventi tecnici (tipi di dato, conteggi, esiti, errori), mai valori di salute. Dopo ogni sincronizzazione, al massimo ogni 15 minuti, le righe nuove vengono inviate anche al tuo server.")
                }

                Section {
                    if lines.isEmpty {
                        Text("Registro vuoto").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        LogLine(line: line)
                            .id(index)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                    }
                } header: {
                    Text("Ultime righe")
                }
            }
            .navigationTitle("Diagnostica")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aggiorna", systemImage: "arrow.clockwise") { reload(proxy) }
                }
            }
            .task { reload(proxy) }
        }
    }

    private func reload(_ proxy: ScrollViewProxy) {
        lines = DiagLog.tail(400)
        size = DiagLog.totalSize
        if !lines.isEmpty {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
    }

    private func send() async {
        sending = true
        sendResult = nil
        DiagLog.info("diagnostica", "invio richiesto a mano")
        if let error = await DiagShipper.shared.ship() {
            sendResult = .failed(error)
        } else {
            sendResult = .ok
        }
        sending = false
    }
}

/// Una riga del registro: ora, categoria colorata per livello, messaggio.
private struct LogLine: View {
    let line: String

    private var parts: (time: String, level: String, category: String, message: String) {
        // Formato: 2026-10-01T16:23:42.123+02:00 [INFO] [sync] messaggio
        let comps = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard comps.count == 4 else { return ("", "", "", line) }
        let time = comps[0].split(separator: "T").last.map { String($0.prefix(8)) } ?? comps[0]
        return (time, comps[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                comps[2].trimmingCharacters(in: CharacterSet(charactersIn: "[]")), comps[3])
    }

    var body: some View {
        let p = parts
        let color: Color = switch p.level {
        case "ERRORE": Palette.failure
        case "WARN": Palette.warning
        default: .secondary
        }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: p.time).foregroundStyle(.secondary)
                Text(verbatim: p.category)
                    .fontWeight(.semibold)
                    .foregroundStyle(color == .secondary ? Palette.brand[1] : color)
            }
            Text(verbatim: p.message)
                .foregroundStyle(color == .secondary ? .primary : color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }
}
