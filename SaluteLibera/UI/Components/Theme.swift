import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Colore che cambia tra modalità chiara e scura.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Palette e gradienti per categoria.
enum Palette {
    // Marchio: corallo → fucsia → viola (come l'icona)
    static let brand: [Color] = [Color(hex: 0xFF7A59), Color(hex: 0xF2366F), Color(hex: 0x9B2FD9)]

    static let activity: [Color] = [.adaptive(light: 0x1FB45A, dark: 0x34D46A), .adaptive(light: 0x8CCF1F, dark: 0xB6F03C)]
    static let heart: [Color] = [.adaptive(light: 0xF0274D, dark: 0xFF4D6A), .adaptive(light: 0xF2559A, dark: 0xFF7AB6)]
    static let sleep: [Color] = [.adaptive(light: 0x4F46E5, dark: 0x7B74FF), .adaptive(light: 0x9D4EDD, dark: 0xC084FC)]
    static let breath: [Color] = [.adaptive(light: 0x0E9AA7, dark: 0x2DD4CF), .adaptive(light: 0x22B8CF, dark: 0x67E8F9)]
    static let energy: [Color] = [.adaptive(light: 0xF2580C, dark: 0xFF7A3D), .adaptive(light: 0xF23A6E, dark: 0xFF5C8A)]
    static let body: [Color] = [.adaptive(light: 0xE8890C, dark: 0xFFB13D), .adaptive(light: 0xE0B000, dark: 0xFFD25C)]
    static let hearing: [Color] = [.adaptive(light: 0x2563EB, dark: 0x60A5FA), .adaptive(light: 0x0EA5E9, dark: 0x7DD3FC)]
    static let mind: [Color] = [.adaptive(light: 0x0D9488, dark: 0x5EEAD4), .adaptive(light: 0x10B981, dark: 0x6EE7B7)]
    static let other: [Color] = [.adaptive(light: 0x64748B, dark: 0x94A3B8), .adaptive(light: 0x8B95A7, dark: 0xCBD5E1)]

    static let success = Color.adaptive(light: 0x16A34A, dark: 0x4ADE80)
    static let warning = Color.adaptive(light: 0xD97706, dark: 0xFBBF24)
    static let failure = Color.adaptive(light: 0xDC2626, dark: 0xF87171)

    // Fasi del sonno
    static let sleepAwake = Color.adaptive(light: 0xF59E0B, dark: 0xFBBF24)
    static let sleepREM = Color.adaptive(light: 0x38BDF8, dark: 0x7DD3FC)
    static let sleepCore = Color.adaptive(light: 0x6366F1, dark: 0x818CF8)
    static let sleepDeep = Color.adaptive(light: 0x5B21B6, dark: 0x8B5CF6)

    static func stage(_ s: SleepStage) -> Color {
        switch s {
        case .awake: sleepAwake
        case .rem: sleepREM
        case .core: sleepCore
        case .deep: sleepDeep
        }
    }

    static func group(_ g: DataGroup) -> [Color] {
        switch g {
        case .attivita: activity
        case .allenamenti: energy
        case .cuore, .ecg: heart
        case .sonno: sleep
        case .respirazione: breath
        case .corpo, .glicemia: body
        case .nutrizione: activity
        case .udito: hearing
        case .mindfulness: mind
        case .ciclo: [.adaptive(light: 0xE11D74, dark: 0xF472B6), .adaptive(light: 0xC026D3, dark: 0xE879F9)]
        case .sintomi, .igiene: other
        }
    }
}

extension LinearGradient {
    static func diagonal(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Sfondo della app: base raggruppata + un alone del marchio in alto.
struct AmbientBackground: View {
    var colors: [Color] = Palette.brand
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                colors: [
                    colors[0], colors[1], colors[2],
                    colors[1].opacity(0.6), colors[2].opacity(0.4), colors[0].opacity(0.5),
                    .clear, .clear, .clear,
                ])
                .opacity(scheme == .dark ? 0.30 : 0.22)
                .frame(height: 420)
                .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                .blur(radius: 30)
        }
        .ignoresSafeArea()
    }
}

/// Scheda "premium": superficie raggruppata con un velo del colore di categoria.
struct CardSurface: ViewModifier {
    let colors: [Color]
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
                shape.fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        shape.fill(LinearGradient(
                            colors: [colors[0].opacity(scheme == .dark ? 0.22 : 0.13),
                                     colors[1].opacity(scheme == .dark ? 0.06 : 0.04), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(colors: [colors[0].opacity(scheme == .dark ? 0.35 : 0.18), .clear],
                                           startPoint: .topLeading, endPoint: .bottom),
                            lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 14, y: 6)
            }
    }
}

extension View {
    func card(_ colors: [Color]) -> some View { modifier(CardSurface(colors: colors)) }
}

/// Intestazione delle schede: simbolo a gradiente + titolo + eventuale nota a destra.
struct CardHeader: View {
    let title: LocalizedStringKey
    let symbol: String
    let colors: [Color]
    var trailing: Text? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(LinearGradient.diagonal(colors))
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors[0])
            Spacer(minLength: 8)
            if let trailing {
                trailing
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Numero grande + unità, allineati alla linea di base.
struct BigValue: View {
    let value: String
    let unit: LocalizedStringKey
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Anello di progresso a gradiente.
struct ProgressRing: View {
    let progress: Double
    let colors: [Color]
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(colors[0].opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center,
                                        startAngle: .degrees(-90), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.spring(duration: 0.9, bounce: 0.25), value: progress)
    }
}

/// Icona arrotondata per le righe delle impostazioni.
struct GroupIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient.diagonal(colors))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
    }
}

extension String {
    /// Solo la prima lettera maiuscola ("giovedì 1 ottobre" → "Giovedì 1 ottobre").
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

enum Format {
    static func integer(_ v: Double) -> String { Int(v.rounded()).formatted(.number) }
    static func integer(_ v: Int) -> String { v.formatted(.number) }

    static func decimal(_ v: Double, digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }

    /// "7 h 24 min"
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int((t / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func bytes(_ b: Int) -> String {
        Int64(b).formatted(.byteCount(style: .file))
    }
}
