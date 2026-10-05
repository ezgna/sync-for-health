import Charts
import SwiftUI

// MARK: - Passi

struct StepsCard: View {
    let steps: Double
    let average: Double?
    let week: [DayValue]

    private var ratio: Double { average.map { $0 > 0 ? steps / $0 : 0 } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Passi", symbol: "figure.walk", colors: Palette.activity)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    BigValue(value: Format.integer(steps), unit: "passi")
                    if let average {
                        let delta = (ratio - 1) * 100
                        HStack(spacing: 4) {
                            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption.weight(.bold))
                            Text(delta >= 0
                                 ? "\(Format.integer(abs(delta)))% sopra la media"
                                 : "\(Format.integer(abs(delta)))% sotto la media")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(delta >= 0 ? Palette.activity[0] : .secondary)
                        Text("Media 7 giorni: \(Format.integer(average))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    ProgressRing(progress: ratio, colors: Palette.activity, lineWidth: 11)
                    VStack(spacing: 0) {
                        Text("\(Format.integer(min(ratio, 9.99) * 100))%")
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text("media")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
            }
            WeekBars(values: week, colors: Palette.activity)
                .frame(height: 78)
        }
        .card(Palette.activity)
        .accessibilityElement(children: .combine)
    }
}

/// Barre degli ultimi 8 giorni, oggi evidenziato.
struct WeekBars: View {
    let values: [DayValue]
    let colors: [Color]

    var body: some View {
        Chart(values) { item in
            let isToday = Calendar.current.isDateInToday(item.date)
            BarMark(x: .value("Giorno", item.date, unit: .day),
                    y: .value("Valore", item.value), width: .fixed(14))
                .clipShape(Capsule())
                .foregroundStyle(isToday
                                 ? AnyShapeStyle(LinearGradient(colors: colors.reversed(), startPoint: .bottom, endPoint: .top))
                                 : AnyShapeStyle(colors[0].opacity(0.22)))
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(max(values.map(\.value).max() ?? 1, 1)))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    .font(.caption2)
            }
        }
    }
}

// MARK: - Sonno

struct SleepCard: View {
    let night: SleepNight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Sonno", symbol: "bed.double.fill", colors: Palette.sleep,
                       trailing: Text("\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened))"))
            HStack(alignment: .firstTextBaseline) {
                BigValue(value: Format.duration(night.asleep), unit: "di sonno", size: 30)
            }
            StageBar(night: night)
                .frame(height: 64)
            HStack(spacing: 0) {
                ForEach([SleepStage.deep, .core, .rem, .awake], id: \.self) { stage in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(Palette.stage(stage)).frame(width: 7, height: 7)
                            Text(stage.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(Format.duration(night.total(stage)))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .card(Palette.sleep)
        .accessibilityElement(children: .combine)
    }
}

/// Ipnogramma compatto: ogni fase alla sua altezza, colori per fase.
struct StageBar: View {
    let night: SleepNight

    var body: some View {
        GeometryReader { geo in
            let total = max(night.end.timeIntervalSince(night.start), 1)
            ZStack(alignment: .leading) {
                // righe guida delle quattro fasi
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle()
                            .fill(Palette.sleep[0].opacity(i % 2 == 0 ? 0.07 : 0.03))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                ForEach(night.segments) { seg in
                    let x = seg.start.timeIntervalSince(night.start) / total * geo.size.width
                    let w = max(seg.duration / total * geo.size.width, 2)
                    let lane = lane(seg.stage)
                    let h = geo.size.height / 4
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Palette.stage(seg.stage).gradient)
                        .frame(width: max(w, 4), height: h - 4)
                        .offset(x: x, y: CGFloat(lane) * h - geo.size.height / 2 + h / 2)
                }
            }
        }
    }

    private func lane(_ s: SleepStage) -> Int {
        switch s {
        case .awake: 0
        case .rem: 1
        case .core: 2
        case .deep: 3
        }
    }
}

// MARK: - Cuore

struct HeartCard: View {
    let resting: Double?
    let restingSeries: [DayValue]
    let hrv: Double?
    let hrvSeries: [DayValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Cuore", symbol: "heart.fill", colors: Palette.heart,
                       trailing: Text("ultimi 7 giorni"))
            HStack(alignment: .top, spacing: 14) {
                metric(title: "A riposo", value: resting, unit: "bpm", series: restingSeries)
                Divider()
                metric(title: "Variabilità (HRV)", value: hrv, unit: "ms", series: hrvSeries)
            }
        }
        .card(Palette.heart)
        .accessibilityElement(children: .combine)
    }

    private func metric(title: LocalizedStringKey, value: Double?, unit: LocalizedStringKey,
                        series: [DayValue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            BigValue(value: value.map(Format.integer) ?? "—", unit: unit, size: 28)
            Sparkline(values: series, colors: Palette.heart)
                .frame(height: 38)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Sparkline: View {
    let values: [DayValue]
    let colors: [Color]

    var body: some View {
        let lo = (values.map(\.value).min() ?? 0)
        let hi = (values.map(\.value).max() ?? 1)
        let pad = max((hi - lo) * 0.25, 1)
        Chart(values) { item in
            AreaMark(x: .value("Giorno", item.date), yStart: .value("Base", lo - pad), yEnd: .value("Valore", item.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [colors[0].opacity(0.28), colors[0].opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Giorno", item.date), y: .value("Valore", item.value))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            if item.id == values.last?.id {
                PointMark(x: .value("Giorno", item.date), y: .value("Valore", item.value))
                    .symbolSize(36)
                    .foregroundStyle(colors[1])
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
    }
}

// MARK: - Energia e In piedi

struct EnergyCard: View {
    let kcal: Double
    let goal: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Energia", symbol: "flame.fill", colors: Palette.energy)
            BigValue(value: Format.integer(kcal), unit: "kcal", size: 28)
            if let goal, goal > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.energy[0].opacity(0.15))
                            Capsule()
                                .fill(LinearGradient(colors: Palette.energy, startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(8, geo.size.width * min(kcal / goal, 1)))
                        }
                    }
                    .frame(height: 8)
                    Text("obiettivo \(Format.integer(goal)) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card(Palette.energy)
        .accessibilityElement(children: .combine)
    }
}

struct StandCard: View {
    let hours: Int
    let goal: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "In piedi", symbol: "figure.stand", colors: Palette.activity)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(hours)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/ \(goal) ore")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<max(goal, 1), id: \.self) { i in
                        Capsule()
                            .fill(i < hours
                                  ? AnyShapeStyle(LinearGradient(colors: Palette.activity, startPoint: .bottom, endPoint: .top))
                                  : AnyShapeStyle(Palette.activity[0].opacity(0.15)))
                    }
                }
                .frame(height: 8)
                Text(hours >= goal ? "obiettivo raggiunto" : "ne mancano \(goal - hours)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card(Palette.activity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Respiro

struct BreathCard: View {
    let rate: Double?
    let oxygen: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Respiro", symbol: "lungs.fill", colors: Palette.breath,
                       trailing: Text("ultima misura"))
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Frequenza")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BigValue(value: rate.map { Format.decimal($0) } ?? "—", unit: "resp/min", size: 26)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ossigeno nel sangue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    BigValue(value: oxygen.map(Format.integer) ?? "—", unit: "%", size: 26)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(Palette.breath)
        .accessibilityElement(children: .combine)
    }
}

/// Scheda vuota quando Salute non ha (ancora) dati.
struct EmptyHighlights: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.text.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(LinearGradient.diagonal(Palette.heart))
                .symbolRenderingMode(.hierarchical)
            Text("Ancora nessun dato di oggi")
                .font(.headline)
            Text("Quando Salute avrà passi, sonno o battito, li vedrai qui. Restano sul tuo iPhone: qui li legge solo l'app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
        .card(Palette.heart)
    }
}

// MARK: - ECG

struct ECGCard: View {
    let ecg: ECGSummary
    @State private var drawn: CGFloat = 0

    private var chipColor: Color { ecg.isReassuring ? Palette.success : Palette.warning }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "ECG", symbol: "waveform.path.ecg", colors: Palette.heart,
                       trailing: Text(ecg.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())))
            HStack(alignment: .center, spacing: 12) {
                BigValue(value: ecg.averageBPM.map(Format.integer) ?? "—", unit: "bpm medi", size: 28)
                Spacer(minLength: 8)
                Label {
                    Text(ecg.classificationTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } icon: {
                    Image(systemName: ecg.isReassuring ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                .font(.caption.weight(.semibold))
                .labelStyle(ChipLabelStyle())
                .foregroundStyle(chipColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(chipColor.opacity(0.14), in: .capsule)
            }
            ZStack {
                ECGPaper()
                ECGTrace(values: ecg.window)
                    .trim(from: 0, to: drawn)
                    .stroke(LinearGradient(colors: Palette.heart, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .shadow(color: Palette.heart[0].opacity(0.35), radius: 3)
                    .padding(.vertical, 10)
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Text("Derivazione I · \(Int((Double(ecg.window.count) / max(ecg.windowHz, 1)).rounded())) secondi")
                Spacer()
                Text("Classificazione di Apple, non una diagnosi")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .card(Palette.heart)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6)) { drawn = 1 }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Carta millimetrata da ECG: griglia fine e griglia ogni 5 quadretti.
struct ECGPaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let minor: CGFloat = 6
            let color = Palette.heart[0]
            let base = scheme == .dark ? 0.10 : 0.07
            var fine = Path(), bold = Path()
            func line(_ from: CGPoint, _ to: CGPoint, major: Bool) {
                if major { bold.move(to: from); bold.addLine(to: to) } else { fine.move(to: from); fine.addLine(to: to) }
            }
            for i in 0...Int(size.width / minor) {
                let x = CGFloat(i) * minor
                line(CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height), major: i % 5 == 0)
            }
            for i in 0...Int(size.height / minor) {
                let y = CGFloat(i) * minor
                line(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y), major: i % 5 == 0)
            }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(base * 0.5)))
            ctx.stroke(fine, with: .color(color.opacity(base)), lineWidth: 0.5)
            ctx.stroke(bold, with: .color(color.opacity(base * 2.2)), lineWidth: 0.8)
        }
    }
}

/// Il tracciato come forma, così si può animare con `trim`.
struct ECGTrace: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let lo = values.min(), let hi = values.max(), hi > lo else { return path }
        let span = hi - lo
        let dx = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: rect.minX + CGFloat(i) * dx,
                            y: rect.maxY - CGFloat((v - lo) / span) * rect.height)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }
}
