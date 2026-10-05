import CoreLocation
import Foundation
import HealthKit

/// Converte gli oggetti HealthKit nei record del payload.
enum Serializer {
    static func source(_ s: HKSample) -> String { s.sourceRevision.source.name }

    /// Metadati come mappa di stringhe (date in ISO 8601, quantità come testo).
    static func metadata(_ m: [String: Any]?) -> [String: String]? {
        guard let m, !m.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (key, value) in m {
            switch value {
            case let d as Date: out[key] = ISO.string(d)
            case let q as HKQuantity: out[key] = q.description
            case let n as NSNumber: out[key] = n.stringValue
            case let s as String: out[key] = s
            default: out[key] = String(describing: value)
            }
        }
        return out
    }

    static func quantity(_ s: HKQuantitySample, unit: HKUnit) -> QuantityRecord {
        QuantityRecord(
            uuid: s.uuid.uuidString,
            tipo: s.quantityType.identifier,
            valore: s.quantity.doubleValue(for: unit),
            unita: unit.unitString,
            inizio: ISO.string(s.startDate),
            fine: ISO.string(s.endDate),
            fonte: source(s),
            metadati: metadata(s.metadata))
    }

    static func category(_ s: HKCategorySample) -> CategoryRecord {
        CategoryRecord(
            uuid: s.uuid.uuidString,
            tipo: s.categoryType.identifier,
            valore: s.value,
            etichetta: categoryLabel(type: s.categoryType.identifier, value: s.value),
            inizio: ISO.string(s.startDate),
            fine: ISO.string(s.endDate),
            fonte: source(s),
            metadati: metadata(s.metadata))
    }

    /// ECG con riepilogo e tracciato completo (derivazione simile a DI, in µV).
    /// Le misure vengono lette per intero prima di costruire il record; un ECG alla volta.
    static func electrocardiogram(_ e: HKElectrocardiogram, store: HKHealthStore) async throws -> ECGRecord {
        var record = electrocardiogramSummary(e)
        record.frequenza_hz = e.samplingFrequency?.doubleValue(for: .hertz())
        let waveform = try await voltages(of: e, store: store)
        if !waveform.isEmpty {
            record.unita_tracciato = "µV"
            record.tracciato = waveform
        }
        return record
    }

    /// Valori in microvolt della derivazione appleWatchSimilarToLeadI, arrotondati a 1 decimale.
    static func voltages(of e: HKElectrocardiogram, store: HKHealthStore) async throws -> [Double] {
        let microvolt = HKUnit.voltUnit(with: .micro)
        var values: [Double] = []
        values.reserveCapacity(max(e.numberOfVoltageMeasurements, 0))
        for try await measurement in HKElectrocardiogramQueryDescriptor(e).results(for: store) {
            guard let q = measurement.quantity(for: .appleWatchSimilarToLeadI) else { continue }
            values.append((q.doubleValue(for: microvolt) * 10).rounded() / 10)
        }
        return values
    }

    static func classificationName(_ c: HKElectrocardiogram.Classification) -> String {
        switch c {
        case .notSet: "notSet"
        case .sinusRhythm: "sinusRhythm"
        case .atrialFibrillation: "atrialFibrillation"
        case .inconclusiveLowHeartRate: "inconclusiveLowHeartRate"
        case .inconclusiveHighHeartRate: "inconclusiveHighHeartRate"
        case .inconclusivePoorReading: "inconclusivePoorReading"
        case .inconclusiveOther: "inconclusiveOther"
        case .unrecognized: "unrecognized"
        @unknown default: "unknown"
        }
    }

    static func electrocardiogramSummary(_ e: HKElectrocardiogram) -> ECGRecord {
        let classification = classificationName(e.classification)
        let symptoms: String = switch e.symptomsStatus {
        case .notSet: "notSet"
        case .none: "none"
        case .present: "present"
        @unknown default: "unknown"
        }
        return ECGRecord(
            uuid: e.uuid.uuidString,
            inizio: ISO.string(e.startDate),
            fine: ISO.string(e.endDate),
            classificazione: classification,
            bpm_medio: e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            sintomi: symptoms,
            fonte: source(e))
    }

    static func audiogram(_ a: HKAudiogramSample) -> AudiogramRecord {
        let hz = HKUnit.hertz()
        let dbhl = HKUnit.decibelHearingLevel()
        let points = a.sensitivityPoints.map { p in
            var point = AudiogramPoint(frequenza_hz: p.frequency.doubleValue(for: hz))
            for test in p.tests where test.type == .air {
                let v = test.sensitivity.doubleValue(for: dbhl)
                switch test.side {
                case .left: point.sinistro_dbhl = v
                case .right: point.destro_dbhl = v
                @unknown default: break
                }
            }
            return point
        }
        return AudiogramRecord(uuid: a.uuid.uuidString, inizio: ISO.string(a.startDate),
                               fine: ISO.string(a.endDate), fonte: source(a), punti: points)
    }

    static func stateOfMind(_ s: HKStateOfMind) -> StateOfMindRecord {
        StateOfMindRecord(
            uuid: s.uuid.uuidString,
            inizio: ISO.string(s.startDate),
            tipo: s.kind == .dailyMood ? "dailyMood" : "momentaryEmotion",
            valenza: s.valence,
            classificazione: StateOfMindNames.valence[s.valenceClassification.rawValue] ?? "unknown",
            etichette: s.labels.map { StateOfMindNames.labels[$0.rawValue] ?? "label_\($0.rawValue)" },
            associazioni: s.associations.map { StateOfMindNames.associations[$0.rawValue] ?? "association_\($0.rawValue)" },
            fonte: source(s))
    }

    /// Allenamento con statistiche; il percorso GPS solo se richiesto nelle impostazioni.
    static func workout(_ w: HKWorkout, store: HKHealthStore, includeRoute: Bool) async -> WorkoutRecord {
        var stats: [String: WorkoutStat] = [:]
        var energy: Double?
        var distance: Double?
        for (type, s) in w.allStatistics {
            let unit = HealthCatalog.entry(for: type.identifier)?.unit ?? .count()
            guard type.is(compatibleWith: unit) else { continue }
            var stat = WorkoutStat(unita: unit.unitString)
            stat.somma = s.sumQuantity()?.doubleValue(for: unit)
            stat.media = s.averageQuantity()?.doubleValue(for: unit)
            stat.minimo = s.minimumQuantity()?.doubleValue(for: unit)
            stat.massimo = s.maximumQuantity()?.doubleValue(for: unit)
            stats[type.identifier] = stat
            if type.identifier == HKQuantityTypeIdentifier.activeEnergyBurned.rawValue {
                energy = stat.somma
            } else if type.identifier.hasPrefix("HKQuantityTypeIdentifierDistance"), distance == nil {
                distance = stat.somma
            }
        }
        var record = WorkoutRecord(
            uuid: w.uuid.uuidString,
            attivita: activityName(w.workoutActivityType),
            inizio: ISO.string(w.startDate),
            fine: ISO.string(w.endDate),
            durata_s: w.duration,
            energia_kcal: energy,
            distanza_m: distance,
            fonte: source(w),
            statistiche: stats.isEmpty ? nil : stats,
            metadati: metadata(w.metadata))
        if includeRoute {
            let points = await route(for: w, store: store)
            record.percorso = points.isEmpty ? nil : points
        }
        return record
    }

    /// Legge i punti GPS di un allenamento (HKWorkoutRoute).
    static func route(for workout: HKWorkout, store: HKHealthStore) async -> [RoutePoint] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [])
        guard let routes = try? await descriptor.result(for: store) else { return [] }
        var points: [RoutePoint] = []
        for route in routes {
            let locations = await withCheckedContinuation { (cont: CheckedContinuation<[RoutePoint], Never>) in
                let acc = RouteAccumulator()
                let q = HKWorkoutRouteQuery(route: route) { _, locs, done, error in
                    if let locs {
                        acc.append(locs.map {
                            RoutePoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude,
                                       alt: $0.altitude, t: ISO.string($0.timestamp))
                        })
                    }
                    if done || error != nil { cont.resume(returning: acc.points) }
                }
                store.execute(q)
            }
            points += locations
        }
        return points
    }

    /// Caratteristiche personali (non cambiano: inviate una volta).
    static func characteristics(store: HKHealthStore) -> Characteristics {
        var c = Characteristics()
        if let dob = try? store.dateOfBirthComponents(), let y = dob.year, let m = dob.month, let d = dob.day {
            c.data_di_nascita = String(format: "%04d-%02d-%02d", y, m, d)
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: c.sesso = "female"
            case .male: c.sesso = "male"
            case .other: c.sesso = "other"
            case .notSet: break
            @unknown default: break
            }
        }
        if let blood = try? store.bloodType().bloodType {
            let names: [HKBloodType: String] = [
                .aPositive: "A+", .aNegative: "A-", .bPositive: "B+", .bNegative: "B-",
                .abPositive: "AB+", .abNegative: "AB-", .oPositive: "0+", .oNegative: "0-",
            ]
            c.gruppo_sanguigno = names[blood]
        }
        if let skin = try? store.fitzpatrickSkinType().skinType, skin != .notSet {
            c.fototipo = ["", "I", "II", "III", "IV", "V", "VI"][min(skin.rawValue, 6)]
        }
        if let wheel = try? store.wheelchairUse().wheelchairUse, wheel != .notSet {
            c.sedia_a_rotelle = wheel == .yes
        }
        if let mode = try? store.activityMoveMode().activityMoveMode {
            c.modalita_movimento = mode == .appleMoveTime ? "appleMoveTime" : "activeEnergy"
        }
        return c
    }

    // MARK: - Etichette

    static func categoryLabel(type: String, value: Int) -> String? {
        let name = type.replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
        let table: [Int: String]
        switch name {
        case "SleepAnalysis":
            table = [0: "inBed", 1: "asleepUnspecified", 2: "awake", 3: "asleepCore", 4: "asleepDeep", 5: "asleepREM"]
        case "AppleStandHour":
            table = [0: "stood", 1: "idle"]
        case "MenstrualFlow", "BleedingAfterPregnancy", "BleedingDuringPregnancy":
            table = [1: "unspecified", 2: "light", 3: "medium", 4: "heavy", 5: "none"]
        case "AppetiteChanges":
            table = [0: "unspecified", 1: "noChange", 2: "decreased", 3: "increased"]
        case "MoodChanges", "SleepChanges":
            table = [0: "present", 1: "notPresent"]
        case "CervicalMucusQuality":
            table = [1: "dry", 2: "sticky", 3: "creamy", 4: "watery", 5: "eggWhite"]
        case "OvulationTestResult":
            table = [1: "negative", 2: "luteinizingHormoneSurge", 3: "indeterminate", 4: "estrogenSurge"]
        case "PregnancyTestResult", "ProgesteroneTestResult":
            table = [1: "negative", 2: "positive", 3: "indeterminate"]
        case "Contraceptive":
            table = [1: "unspecified", 2: "implant", 3: "injection", 4: "intrauterineDevice",
                     5: "intravaginalRing", 6: "oral", 7: "patch"]
        case "AppleWalkingSteadinessEvent":
            table = [1: "initialLow", 2: "initialVeryLow", 3: "repeatLow", 4: "repeatVeryLow"]
        case "LowCardioFitnessEvent":
            table = [1: "lowFitness"]
        case "EnvironmentalAudioExposureEvent":
            table = [1: "momentaryLimit"]
        case "HeadphoneAudioExposureEvent":
            table = [1: "sevenDayLimit"]
        case "AbdominalCramps", "Acne", "BladderIncontinence", "Bloating", "BreastPain", "ChestTightnessOrPain",
             "Chills", "Constipation", "Coughing", "Diarrhea", "Dizziness", "DrySkin", "Fainting", "Fatigue",
             "Fever", "GeneralizedBodyAche", "HairLoss", "Headache", "Heartburn", "HotFlashes", "LossOfSmell",
             "LossOfTaste", "LowerBackPain", "MemoryLapse", "Nausea", "NightSweats", "PelvicPain",
             "RapidPoundingOrFlutteringHeartbeat", "RunnyNose", "ShortnessOfBreath", "SinusCongestion",
             "SkippedHeartbeat", "SoreThroat", "VaginalDryness", "Vomiting", "Wheezing":
            table = [0: "unspecified", 1: "notPresent", 2: "mild", 3: "moderate", 4: "severe"]
        default:
            table = [0: "notApplicable"]
        }
        return table[value]
    }

    static func activityName(_ type: HKWorkoutActivityType) -> String {
        activityNames[type.rawValue] ?? "activity_\(type.rawValue)"
    }

    /// Nomi stabili (snake_case inglese) per HKWorkoutActivityType, per valore grezzo.
    static let activityNames: [UInt: String] = [
        1: "american_football",
        2: "archery",
        3: "australian_football",
        4: "badminton",
        5: "baseball",
        6: "basketball",
        7: "bowling",
        8: "boxing",
        9: "climbing",
        10: "cricket",
        11: "cross_training",
        12: "curling",
        13: "cycling",
        14: "dance",
        15: "dance_inspired_training",
        16: "elliptical",
        17: "equestrian_sports",
        18: "fencing",
        19: "fishing",
        20: "functional_strength_training",
        21: "golf",
        22: "gymnastics",
        23: "handball",
        24: "hiking",
        25: "hockey",
        26: "hunting",
        27: "lacrosse",
        28: "martial_arts",
        29: "mind_and_body",
        30: "mixed_metabolic_cardio_training",
        31: "paddle_sports",
        32: "play",
        33: "preparation_and_recovery",
        34: "racquetball",
        35: "rowing",
        36: "rugby",
        37: "running",
        38: "sailing",
        39: "skating_sports",
        40: "snow_sports",
        41: "soccer",
        42: "softball",
        43: "squash",
        44: "stair_climbing",
        45: "surfing_sports",
        46: "swimming",
        47: "table_tennis",
        48: "tennis",
        49: "track_and_field",
        50: "traditional_strength_training",
        51: "volleyball",
        52: "walking",
        53: "water_fitness",
        54: "water_polo",
        55: "water_sports",
        56: "wrestling",
        57: "yoga",
        58: "barre",
        59: "core_training",
        60: "cross_country_skiing",
        61: "downhill_skiing",
        62: "flexibility",
        63: "high_intensity_interval_training",
        64: "jump_rope",
        65: "kickboxing",
        66: "pilates",
        67: "snowboarding",
        68: "stairs",
        69: "step_training",
        70: "wheelchair_walk_pace",
        71: "wheelchair_run_pace",
        72: "tai_chi",
        73: "mixed_cardio",
        74: "hand_cycling",
        75: "disc_sports",
        76: "fitness_gaming",
        77: "cardio_dance",
        78: "social_dance",
        79: "pickleball",
        80: "cooldown",
        82: "swim_bike_run",
        83: "transition",
        84: "underwater_diving",
        3000: "other",
    ]
}

/// Accumula i punti GPS che HKWorkoutRouteQuery consegna a blocchi (sempre in serie).
final class RouteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RoutePoint] = []

    func append(_ points: [RoutePoint]) {
        lock.lock(); storage += points; lock.unlock()
    }

    var points: [RoutePoint] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Nomi stabili per le enumerazioni di HKStateOfMind (generati dagli header dell'SDK).
enum StateOfMindNames {
    static let labels: [Int: String] = [
        1: "amazed",
        2: "amused",
        3: "angry",
        32: "annoyed",
        4: "anxious",
        5: "ashamed",
        6: "brave",
        7: "calm",
        33: "confident",
        8: "content",
        9: "disappointed",
        10: "discouraged",
        11: "disgusted",
        34: "drained",
        12: "embarrassed",
        13: "excited",
        14: "frustrated",
        15: "grateful",
        16: "guilty",
        17: "happy",
        35: "hopeful",
        18: "hopeless",
        36: "indifferent",
        19: "irritated",
        20: "jealous",
        21: "joyful",
        22: "lonely",
        37: "overwhelmed",
        23: "passionate",
        24: "peaceful",
        25: "proud",
        26: "relieved",
        27: "sad",
        38: "satisfied",
        28: "scared",
        29: "stressed",
        30: "surprised",
        31: "worried",
    ]
    static let associations: [Int: String] = [
        1: "community",
        2: "currentEvents",
        3: "dating",
        4: "education",
        5: "family",
        6: "fitness",
        7: "friends",
        8: "health",
        9: "hobbies",
        10: "identity",
        11: "money",
        12: "partner",
        13: "selfCare",
        14: "spirituality",
        15: "tasks",
        16: "travel",
        18: "weather",
        17: "work",
    ]
    static let valence: [Int: String] = [
        4: "neutral",
        6: "pleasant",
        5: "slightlyPleasant",
        3: "slightlyUnpleasant",
        2: "unpleasant",
        7: "veryPleasant",
        1: "veryUnpleasant",
    ]
}
