import Charts
import SwiftUI

/// Cronologia degli invii: riepilogo della settimana e linea del tempo per giorno.
struct SendsView: View {
    @Environment(SyncLog.self) private var log

    private var days: [(Date, [SyncRecord])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: log.records) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if log.records.isEmpty {
                    ContentUnavailableView {
                        Label("Nessun invio ancora", systemImage: "paperplane")
                    } description: {
                        Text("Qui comparirà ogni sincronizzazione, con l'esito e quanti campioni sono partiti.")
                    }
                    .padding(.top, 80)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        WeekSummary(records: log.records)
                        ForEach(days, id: \.0) { day, records in
                            Text(dayTitle(day))
                                .font(.headline)
                                .padding(.top, 12)
                                .padding(.leading, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                                    TimelineRow(record: record,
                                                isFirst: index == 0,
                                                isLast: index == records.count - 1)
                                }
                            }
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: .rect(cornerRadius: 24, style: .continuous))
                        }
                        Text("Vengono conservati gli ultimi \(SyncLog.limit) invii.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(AppEnvironment.scrollToBottom ? .bottom : .top)
            .background(AmbientBackground())
            .navigationTitle("Invii")
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "Oggi") }
        if cal.isDateInYesterday(day) { return String(localized: "Ieri") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst
    }
}

/// Riepilogo: campioni al giorno negli ultimi 7 giorni.
struct WeekSummary: View {
    let records: [SyncRecord]

    private enum Kind: Int { case delivered, waiting, failed }

    private struct Bar: Identifiable {
        let date: Date
        let kind: Kind
        let count: Int
        var id: String { "\(date.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    private static func kind(_ r: SyncRecord) -> Kind {
        if r.delivered || r.outcome == .nienteDaInviare { return .delivered }
        if r.outcome == .inAttesa || r.outcome == .interrotto { return .waiting }
        return .failed
    }

    /// Invii al giorno: consegnati (anche parzialmente), in attesa, non riusciti.
    private var bars: [Bar] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<7).reversed().flatMap { offset -> [Bar] in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let list = records.filter { cal.isDate($0.date, inSameDayAs: day) }
            return [Kind.delivered, .waiting, .failed].map { k in
                Bar(date: day, kind: k, count: list.filter { Self.kind($0) == k }.count)
            }
        }
    }

    /// Campioni consegnati in settimana, inclusi quelli degli invii parziali.
    private var samplesWeek: Int {
        weekRecords.filter(\.delivered).reduce(0) { $0 + $1.samples + $1.deleted }
    }

    private var weekRecords: [SyncRecord] {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        return records.filter { $0.date >= since }
    }

    /// Quota di invii che hanno consegnato dati. «In attesa» e «già in pari» non contano.
    private var successRate: Double {
        let relevant = weekRecords.filter { Self.kind($0) != .waiting && $0.outcome != .nienteDaInviare }
        guard !relevant.isEmpty else { return 1 }
        return Double(relevant.filter(\.delivered).count) / Double(relevant.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Ultimi 7 giorni", symbol: "chart.bar.fill", colors: Palette.brand)
            HStack(spacing: 0) {
                figure(Format.integer(samplesWeek), "campioni")
                Spacer()
                figure(Format.integer(weekRecords.count), "invii")
                Spacer()
                figure((successRate).formatted(.percent.precision(.fractionLength(0))), "consegnati")
            }
            Chart(bars) { bar in
                BarMark(x: .value("Giorno", bar.date, unit: .day), y: .value("Invii", bar.count),
                        width: .fixed(16), stacking: .standard)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(style(bar.kind))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                        .font(.caption2)
                }
            }
            .frame(height: 96)
            HStack(spacing: 14) {
                legend(color: Palette.brand[1], "consegnati")
                legend(color: Color.secondary.opacity(0.5), "in attesa")
                legend(color: Palette.failure, "non riusciti")
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func style(_ kind: Kind) -> AnyShapeStyle {
        switch kind {
        case .delivered:
            AnyShapeStyle(LinearGradient(colors: [Palette.brand[2], Palette.brand[1]], startPoint: .bottom, endPoint: .top))
        case .waiting: AnyShapeStyle(Color.secondary.opacity(0.35))
        case .failed: AnyShapeStyle(Palette.failure)
        }
    }

    private func legend(color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func figure(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Una riga della linea del tempo.
struct TimelineRow: View {
    let record: SyncRecord
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 62, alignment: .trailing)
                .padding(.top, 13)

            // Binario con il pallino colorato
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : Color(.separator)).frame(width: 2, height: 14)
                Circle()
                    .fill(record.statusColor.gradient)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2.5))
                Rectangle().fill(isLast ? .clear : Color(.separator)).frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatusChip(record: record)
                    Label(record.triggerTitle, systemImage: record.triggerSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(record.summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = record.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let message = record.message, record.outcome != .riuscito,
                   !(record.outcome == .inAttesa && record.samples == 0) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(record.statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}

struct StatusChip: View {
    let record: SyncRecord

    var body: some View {
        Label(record.statusTitle, systemImage: record.statusSymbol)
            .font(.caption.weight(.semibold))
            .labelStyle(ChipLabelStyle())
            .foregroundStyle(record.statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(record.statusColor.opacity(0.14), in: .capsule)
    }
}

struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension SyncRecord {
    var statusTitle: LocalizedStringKey {
        switch outcome {
        case .riuscito: "Riuscito"
        case .errore: "Errore"
        case .nienteDaInviare: "Già in pari"
        case .interrotto: "Interrotto"
        case .parziale: "Parziale · in pausa"
        case .inAttesa: "In attesa"
        }
    }

    var statusSymbol: String {
        switch outcome {
        case .riuscito: "checkmark"
        case .errore: "exclamationmark.triangle.fill"
        case .nienteDaInviare: "equal"
        case .interrotto: "pause.fill"
        case .parziale: "pause.circle.fill"
        case .inAttesa: "lock.fill"
        }
    }

    var statusColor: Color {
        switch outcome {
        case .riuscito: Palette.success
        case .errore: Palette.failure
        case .nienteDaInviare, .inAttesa: .secondary
        case .interrotto, .parziale: Palette.warning
        }
    }

    var triggerTitle: LocalizedStringKey {
        switch trigger {
        case .manuale: "A mano"
        case .automatico: "Nuovi dati"
        case .background: "In background"
        case .prova: "Prova"
        case .storico: "Storico completo"
        }
    }

    var triggerSymbol: String {
        switch trigger {
        case .manuale: "hand.tap.fill"
        case .automatico: "bolt.heart.fill"
        case .background: "moon.fill"
        case .prova: "antenna.radiowaves.left.and.right"
        case .storico: "clock.arrow.circlepath"
        }
    }

    var summary: String {
        switch outcome {
        case .nienteDaInviare:
            return String(localized: "Nessun dato nuovo da inviare")
        case .inAttesa where samples == 0:
            return String(localized: "Salute non è leggibile con l'iPhone bloccato")
        case .errore where samples == 0, .interrotto where samples == 0:
            return String(localized: "Niente è andato perso: si riparte da qui")
        case .parziale, .interrotto, .errore, .inAttesa:
            var parts = [String(localized: "\(Format.integer(samples)) campioni inviati")]
            if deleted > 0 { parts.append(String(localized: "\(deleted) eliminati")) }
            return parts.joined(separator: " · ")
        default:
            var parts = [String(localized: "\(Format.integer(samples)) campioni")]
            if deleted > 0 { parts.append(String(localized: "\(deleted) eliminati")) }
            return parts.joined(separator: " · ")
        }
    }

    /// Riga secondaria: dimensione, richieste e durata.
    var detail: String? {
        guard delivered else { return nil }
        var parts: [String] = []
        if bytes > 0 { parts.append(Format.bytes(bytes)) }
        if requests > 1 { parts.append(String(localized: "\(requests) blocchi")) }
        parts.append(duration < 60
                     ? duration.formatted(.number.precision(.fractionLength(1))) + " s"
                     : Format.duration(duration))
        return parts.joined(separator: " · ")
    }
}
