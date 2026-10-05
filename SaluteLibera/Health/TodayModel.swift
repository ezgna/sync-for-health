import Foundation
import HealthKit
import Observation

/// Valore giornaliero per i grafici.
struct DayValue: Identifiable, Sendable, Hashable {
    let date: Date
    let value: Double
    var id: Date { date }
}

enum SleepStage: String, Sendable, CaseIterable {
    case awake, rem, core, deep

    var title: LocalizedStringResource {
        switch self {
        case .awake: "Sveglio"
        case .rem: "REM"
        case .core: "Leggero"
        case .deep: "Profondo"
        }
    }
}

struct SleepSegment: Sendable, Hashable, Identifiable {
    let stage: SleepStage
    let start: Date
    let end: Date
    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct SleepNight: Sendable, Hashable {
    let segments: [SleepSegment]
    var start: Date { segments.first?.start ?? .now }
    var end: Date { segments.last?.end ?? .now }
    var asleep: TimeInterval { segments.filter { $0.stage != .awake }.reduce(0) { $0 + $1.duration } }
    func total(_ stage: SleepStage) -> TimeInterval {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
    }
}

/// Ultimo ECG per la scheda in Oggi: riepilogo e una finestra del tracciato.
struct ECGSummary: Sendable, Hashable {
    let date: Date
    /// Nome HealthKit della classificazione (es. "sinusRhythm").
    let classification: String
    let averageBPM: Double?
    /// Finestra di qualche secondo del tracciato, in µV.
    let window: [Double]
    /// Campioni al secondo della finestra (dopo l'eventuale decimazione).
    let windowHz: Double

    var classificationTitle: LocalizedStringResource {
        switch classification {
        case "sinusRhythm": "Ritmo sinusale"
        case "atrialFibrillation": "Fibrillazione atriale"
        case "inconclusiveLowHeartRate": "Non conclusivo · battito basso"
        case "inconclusiveHighHeartRate": "Non conclusivo · battito alto"
        case "inconclusivePoorReading": "Registrazione scadente"
        case "inconclusiveOther", "unrecognized": "Non conclusivo"
        default: "Non classificato"
        }
    }

    var isReassuring: Bool { classification == "sinusRhythm" }

    /// Prende `seconds` secondi a partire da `offset` e li decima a circa `targetHz`.
    static func window(from values: [Double], hz: Double, offset: Double = 2,
                       seconds: Double = 4, targetHz: Double = 128) -> (values: [Double], hz: Double) {
        guard hz > 0, !values.isEmpty else { return ([], 0) }
        let start = min(Int(offset * hz), max(values.count - 1, 0))
        let end = min(values.count, start + Int(seconds * hz))
        let step = max(1, Int((hz / targetHz).rounded()))
        let slice = stride(from: start, to: end, by: step).map { values[$0] }
        return (slice, hz / Double(step))
    }
}

/// I numeri di oggi, letti in locale da HealthKit (mai inviati da qui).
struct TodaySnapshot: Sendable {
    var steps: Double?
    var stepsWeek: [DayValue] = []
    var activeEnergy: Double?
    var energyGoal: Double?
    var exerciseMinutes: Double?
    var standHours: Int?
    var standGoal: Int?
    var sleep: SleepNight?
    var restingHR: Double?
    var restingSeries: [DayValue] = []
    var hrv: Double?
    var hrvSeries: [DayValue] = []
    var respiratoryRate: Double?
    var oxygen: Double?
    var ecg: ECGSummary?

    /// Media dei 7 giorni precedenti (oggi escluso).
    var stepsAverage: Double? {
        let past = stepsWeek.filter { !Calendar.current.isDateInToday($0.date) && $0.value > 0 }
        guard !past.isEmpty else { return nil }
        return past.map(\.value).reduce(0, +) / Double(past.count)
    }

    var isEmpty: Bool {
        steps == nil && activeEnergy == nil && sleep == nil && restingHR == nil && hrv == nil
    }
}

@MainActor
@Observable
final class TodayModel {
    static let shared = TodayModel()

    private(set) var snapshot = TodaySnapshot()
    private(set) var loaded = false

    func refresh() async {
        if AppEnvironment.isDemo {
            snapshot = DemoData.today()
            loaded = true
            return
        }
        guard Health.isAvailable else { loaded = true; return }
        snapshot = await TodayLoader.load()
        loaded = true
    }
}

/// Lettura dei valori di oggi con le query asincrone di HealthKit.
enum TodayLoader {
    static func load() async -> TodaySnapshot {
        var s = TodaySnapshot()
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let weekStart = cal.date(byAdding: .day, value: -7, to: today)!
        let bpm = HKUnit.count().unitDivided(by: .minute())

        if let week = await daily(.stepCount, from: weekStart, options: .cumulativeSum, unit: .count()) {
            s.stepsWeek = week
            s.steps = week.first { cal.isDateInToday($0.date) }?.value ?? 0
        }
        s.activeEnergy = await daily(.activeEnergyBurned, from: today, options: .cumulativeSum, unit: .kilocalorie())?.last?.value
        s.exerciseMinutes = await daily(.appleExerciseTime, from: today, options: .cumulativeSum, unit: .minute())?.last?.value

        if let rhr = await daily(.restingHeartRate, from: weekStart, options: .discreteAverage, unit: bpm) {
            s.restingSeries = rhr
            s.restingHR = rhr.last?.value
        }
        if let hrv = await daily(.heartRateVariabilitySDNN, from: weekStart, options: .discreteAverage, unit: .secondUnit(with: .milli)) {
            s.hrvSeries = hrv
            s.hrv = hrv.last?.value
        }
        s.respiratoryRate = await latest(.respiratoryRate, unit: bpm)
        if let o2 = await latest(.oxygenSaturation, unit: .percent()) { s.oxygen = o2 * 100 }

        if let summary = await activitySummary() {
            s.energyGoal = summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())
            s.standHours = Int(summary.appleStandHours.doubleValue(for: .count()))
            s.standGoal = Int(summary.appleStandHoursGoal.doubleValue(for: .count()))
            if s.activeEnergy == nil { s.activeEnergy = summary.activeEnergyBurned.doubleValue(for: .kilocalorie()) }
        }
        s.sleep = await lastNight()
        s.ecg = await lastECG()
        return s
    }

    private static func daily(_ id: HKQuantityTypeIdentifier, from start: Date,
                              options: HKStatisticsOptions, unit: HKUnit) async -> [DayValue]? {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: options,
            anchorDate: Calendar.current.startOfDay(for: .now),
            intervalComponents: DateComponents(day: 1))
        guard let collection = try? await query.result(for: Health.store) else { return nil }
        var out: [DayValue] = []
        collection.enumerateStatistics(from: start, to: .now) { stat, _ in
            let q = options.contains(.cumulativeSum) ? stat.sumQuantity() : stat.averageQuantity()
            if let q { out.append(DayValue(date: stat.startDate, value: q.doubleValue(for: unit))) }
        }
        return out.isEmpty ? nil : out
    }

    private static func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let since = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id),
                                         predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        return try? await query.result(for: Health.store).first?.quantity.doubleValue(for: unit)
    }

    private static func activitySummary() async -> HKActivitySummary? {
        var comps = Calendar.current.dateComponents([.era, .year, .month, .day], from: .now)
        comps.calendar = Calendar.current
        let query = HKActivitySummaryQueryDescriptor(
            predicate: HKQuery.predicateForActivitySummary(with: comps))
        return try? await query.result(for: Health.store).first
    }

    /// Ultimo ECG registrato (riepilogo + 4 secondi di tracciato).
    private static func lastECG() async -> ECGSummary? {
        let query = HKSampleQueryDescriptor(
            predicates: [.electrocardiogram()],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 1)
        guard let ecg = try? await query.result(for: Health.store).first else { return nil }
        let hz = ecg.samplingFrequency?.doubleValue(for: .hertz()) ?? 512
        let values = (try? await Serializer.voltages(of: ecg, store: Health.store)) ?? []
        let w = ECGSummary.window(from: values, hz: hz)
        return ECGSummary(
            date: ecg.startDate,
            classification: Serializer.classificationName(ecg.classification),
            averageBPM: ecg.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            window: w.values, windowHz: w.hz)
    }

    /// Ultima notte: campioni di sonno da ieri alle 18 a oggi alle 14.
    private static func lastNight() async -> SleepNight? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let from = cal.date(byAdding: .hour, value: -6, to: today)!
        let to = cal.date(byAdding: .hour, value: 14, to: today)!
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: from, end: to))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await query.result(for: Health.store), !samples.isEmpty else { return nil }
        // Preferisce le fasi dettagliate (Apple Watch); altrimenti "addormentato" generico.
        let staged = samples.filter { [2, 3, 4, 5].contains($0.value) }
        let use = staged.isEmpty ? samples.filter { $0.value == 1 } : staged
        let segments = use.map { s -> SleepSegment in
            let stage: SleepStage = switch s.value {
            case 2: .awake
            case 5: .rem
            case 4: .deep
            default: .core
            }
            return SleepSegment(stage: stage, start: s.startDate, end: s.endDate)
        }
        return segments.isEmpty ? nil : SleepNight(segments: segments)
    }
}
