import Foundation
import HealthKit

/// Gruppi di dati: l'utente concede l'accesso a Salute gruppo per gruppo.
/// Nessun gruppo è attivo di serie; se ne possono aggiungere altri in qualsiasi momento.
enum DataGroup: String, CaseIterable, Identifiable, Codable, Sendable {
    case attivita, allenamenti, cuore, ecg, sonno, respirazione, corpo, glicemia
    case nutrizione, udito, mindfulness, ciclo, sintomi, igiene

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .attivita: "Attività"
        case .allenamenti: "Allenamenti"
        case .cuore: "Cuore"
        case .ecg: "ECG"
        case .sonno: "Sonno"
        case .respirazione: "Respirazione"
        case .corpo: "Corpo"
        case .glicemia: "Glicemia e alcol"
        case .nutrizione: "Nutrizione"
        case .udito: "Udito"
        case .mindfulness: "Mindfulness"
        case .ciclo: "Ciclo e salute riproduttiva"
        case .sintomi: "Sintomi"
        case .igiene: "Igiene"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .attivita: "Passi, distanze, energia, piani, mobilità"
        case .allenamenti: "Tipo, durata, energia e statistiche degli allenamenti"
        case .cuore: "Frequenza, HRV, pressione, notifiche del ritmo"
        case .ecg: "Registrazioni ECG con il tracciato completo"
        case .sonno: "Fasi del sonno, temperatura notturna, apnee"
        case .respirazione: "Frequenza respiratoria, ossigeno, spirometria"
        case .corpo: "Peso, misure, temperatura, cadute, dati personali"
        case .glicemia: "Glicemia, insulina, alcol"
        case .nutrizione: "Calorie, acqua, macronutrienti, vitamine, minerali"
        case .udito: "Esposizione sonora, audiogrammi"
        case .mindfulness: "Minuti di consapevolezza, stato d'animo"
        case .ciclo: "Ciclo mestruale, test, gravidanza, attività sessuale"
        case .sintomi: "Mal di testa, febbre, tosse e altri sintomi registrati"
        case .igiene: "Lavaggio delle mani, spazzolino"
        }
    }

    var symbol: String {
        switch self {
        case .attivita: "figure.walk"
        case .allenamenti: "figure.run"
        case .cuore: "heart.fill"
        case .ecg: "waveform.path.ecg"
        case .sonno: "bed.double.fill"
        case .respirazione: "lungs.fill"
        case .corpo: "figure.arms.open"
        case .glicemia: "drop.fill"
        case .nutrizione: "fork.knife"
        case .udito: "ear.fill"
        case .mindfulness: "brain.head.profile.fill"
        case .ciclo: "calendar.circle.fill"
        case .sintomi: "list.bullet.clipboard.fill"
        case .igiene: "hands.sparkles.fill"
        }
    }

    /// Gruppi con dati particolarmente delicati: nell'elenco portano un'etichetta.
    var isSensitive: Bool {
        switch self {
        case .ecg, .ciclo, .sintomi, .glicemia: true
        default: false
        }
    }
}

/// Tipo di campione HealthKit e come serializzarlo.
enum EntryKind: Sendable, Equatable {
    /// Campione quantitativo con l'unità canonica usata nel payload.
    case quantity(unit: String)
    case category
    case correlation
    case workout
    case electrocardiogram
    case audiogram
    case stateOfMind
}

/// Una voce del catalogo: un identificatore HealthKit, il suo gruppo e la sua unità.
struct CatalogEntry: Sendable, Identifiable, Hashable {
    let identifier: String
    let group: DataGroup
    let kind: EntryKind
    /// Se il tipo merita la consegna in background "immediata" (invece che oraria).
    let immediate: Bool

    var id: String { identifier }

    static func == (a: CatalogEntry, b: CatalogEntry) -> Bool { a.identifier == b.identifier }
    func hash(into h: inout Hasher) { h.combine(identifier) }

    /// Il tipo HealthKit corrispondente, oppure nil se non esiste su questa versione di iOS.
    var sampleType: HKSampleType? {
        switch kind {
        case .quantity:
            return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
        case .category:
            return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
        case .correlation:
            return HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: identifier))
        case .workout:
            return HKObjectType.workoutType()
        case .electrocardiogram:
            return HKObjectType.electrocardiogramType()
        case .audiogram:
            return HKObjectType.audiogramSampleType()
        case .stateOfMind:
            return HKObjectType.stateOfMindType()
        }
    }

    /// L'unità HealthKit (solo per i campioni quantitativi).
    var unit: HKUnit? {
        guard case .quantity(let u) = kind else { return nil }
        return HealthCatalog.makeUnit(u)
    }

    var unitString: String? {
        guard case .quantity(let u) = kind else { return nil }
        return u
    }
}

/// Catalogo di tutti i tipi leggibili che l'app conosce.
/// La lista è costruita da identificatori noti; i tipi non disponibili sulla versione
/// di iOS in uso vengono scartati a runtime (`sampleType == nil`).
enum HealthCatalog {
    private static let q = "HKQuantityTypeIdentifier"
    private static let c = "HKCategoryTypeIdentifier"

    /// (nome breve, gruppo, unità canonica)
    private static let quantities: [(String, DataGroup, String)] = [
        // Attività
        ("StepCount", .attivita, "count"),
        ("DistanceWalkingRunning", .attivita, "m"),
        ("DistanceCycling", .attivita, "m"),
        ("DistanceWheelchair", .attivita, "m"),
        ("DistanceSwimming", .attivita, "m"),
        ("DistanceDownhillSnowSports", .attivita, "m"),
        ("DistanceCrossCountrySkiing", .attivita, "m"),
        ("DistancePaddleSports", .attivita, "m"),
        ("DistanceRowing", .attivita, "m"),
        ("DistanceSkatingSports", .attivita, "m"),
        ("PushCount", .attivita, "count"),
        ("SwimmingStrokeCount", .attivita, "count"),
        ("FlightsClimbed", .attivita, "count"),
        ("ActiveEnergyBurned", .attivita, "kcal"),
        ("BasalEnergyBurned", .attivita, "kcal"),
        ("AppleExerciseTime", .attivita, "min"),
        ("AppleMoveTime", .attivita, "min"),
        ("AppleStandTime", .attivita, "min"),
        ("PhysicalEffort", .attivita, "kcal/hr·kg"),
        ("WorkoutEffortScore", .attivita, "appleEffortScore"),
        ("EstimatedWorkoutEffortScore", .attivita, "appleEffortScore"),
        ("RunningSpeed", .attivita, "m/s"),
        ("RunningPower", .attivita, "W"),
        ("RunningStrideLength", .attivita, "m"),
        ("RunningVerticalOscillation", .attivita, "cm"),
        ("RunningGroundContactTime", .attivita, "ms"),
        ("CyclingSpeed", .attivita, "m/s"),
        ("CyclingPower", .attivita, "W"),
        ("CyclingCadence", .attivita, "count/min"),
        ("CyclingFunctionalThresholdPower", .attivita, "W"),
        ("CrossCountrySkiingSpeed", .attivita, "m/s"),
        ("PaddleSportsSpeed", .attivita, "m/s"),
        ("RowingSpeed", .attivita, "m/s"),
        ("WalkingSpeed", .attivita, "m/s"),
        ("WalkingStepLength", .attivita, "m"),
        ("WalkingDoubleSupportPercentage", .attivita, "%"),
        ("WalkingAsymmetryPercentage", .attivita, "%"),
        ("StairAscentSpeed", .attivita, "m/s"),
        ("StairDescentSpeed", .attivita, "m/s"),
        ("SixMinuteWalkTestDistance", .attivita, "m"),
        ("AppleWalkingSteadiness", .attivita, "%"),
        ("TimeInDaylight", .attivita, "min"),
        ("UnderwaterDepth", .attivita, "m"),
        // Cuore
        ("HeartRate", .cuore, "count/min"),
        ("RestingHeartRate", .cuore, "count/min"),
        ("WalkingHeartRateAverage", .cuore, "count/min"),
        ("HeartRateVariabilitySDNN", .cuore, "ms"),
        ("HeartRateRecoveryOneMinute", .cuore, "count/min"),
        ("AtrialFibrillationBurden", .cuore, "%"),
        ("VO2Max", .cuore, "ml/kg·min"),
        ("PeripheralPerfusionIndex", .cuore, "%"),
        ("BloodPressureSystolic", .cuore, "mmHg"),
        ("BloodPressureDiastolic", .cuore, "mmHg"),
        // Sonno
        ("AppleSleepingWristTemperature", .sonno, "degC"),
        ("AppleSleepingBreathingDisturbances", .sonno, "count"),
        // Respirazione
        ("RespiratoryRate", .respirazione, "count/min"),
        ("OxygenSaturation", .respirazione, "%"),
        ("ForcedVitalCapacity", .respirazione, "L"),
        ("ForcedExpiratoryVolume1", .respirazione, "L"),
        ("PeakExpiratoryFlowRate", .respirazione, "L/min"),
        ("InhalerUsage", .respirazione, "count"),
        // Corpo
        ("BodyMass", .corpo, "kg"),
        ("BodyMassIndex", .corpo, "count"),
        ("BodyFatPercentage", .corpo, "%"),
        ("LeanBodyMass", .corpo, "kg"),
        ("Height", .corpo, "m"),
        ("WaistCircumference", .corpo, "m"),
        ("BodyTemperature", .corpo, "degC"),
        ("BasalBodyTemperature", .corpo, "degC"),
        ("BloodGlucose", .glicemia, "mg/dL"),
        ("InsulinDelivery", .glicemia, "IU"),
        ("BloodAlcoholContent", .glicemia, "%"),
        ("NumberOfAlcoholicBeverages", .glicemia, "count"),
        ("ElectrodermalActivity", .corpo, "S"),
        ("NumberOfTimesFallen", .corpo, "count"),
        ("UVExposure", .corpo, "count"),
        ("WaterTemperature", .corpo, "degC"),
        // Udito
        ("EnvironmentalAudioExposure", .udito, "dBASPL"),
        ("HeadphoneAudioExposure", .udito, "dBASPL"),
        ("EnvironmentalSoundReduction", .udito, "dBASPL"),
        // Nutrizione
        ("DietaryEnergyConsumed", .nutrizione, "kcal"),
        ("DietaryWater", .nutrizione, "mL"),
        ("DietaryCarbohydrates", .nutrizione, "g"),
        ("DietaryProtein", .nutrizione, "g"),
        ("DietaryFatTotal", .nutrizione, "g"),
        ("DietaryFatSaturated", .nutrizione, "g"),
        ("DietaryFatMonounsaturated", .nutrizione, "g"),
        ("DietaryFatPolyunsaturated", .nutrizione, "g"),
        ("DietaryCholesterol", .nutrizione, "g"),
        ("DietaryFiber", .nutrizione, "g"),
        ("DietarySugar", .nutrizione, "g"),
        ("DietarySodium", .nutrizione, "g"),
        ("DietaryCaffeine", .nutrizione, "g"),
        ("DietaryCalcium", .nutrizione, "g"),
        ("DietaryChloride", .nutrizione, "g"),
        ("DietaryChromium", .nutrizione, "g"),
        ("DietaryCopper", .nutrizione, "g"),
        ("DietaryFolate", .nutrizione, "g"),
        ("DietaryIodine", .nutrizione, "g"),
        ("DietaryIron", .nutrizione, "g"),
        ("DietaryMagnesium", .nutrizione, "g"),
        ("DietaryManganese", .nutrizione, "g"),
        ("DietaryMolybdenum", .nutrizione, "g"),
        ("DietaryNiacin", .nutrizione, "g"),
        ("DietaryPantothenicAcid", .nutrizione, "g"),
        ("DietaryPhosphorus", .nutrizione, "g"),
        ("DietaryPotassium", .nutrizione, "g"),
        ("DietaryRiboflavin", .nutrizione, "g"),
        ("DietarySelenium", .nutrizione, "g"),
        ("DietaryThiamin", .nutrizione, "g"),
        ("DietaryBiotin", .nutrizione, "g"),
        ("DietaryVitaminA", .nutrizione, "g"),
        ("DietaryVitaminB6", .nutrizione, "g"),
        ("DietaryVitaminB12", .nutrizione, "g"),
        ("DietaryVitaminC", .nutrizione, "g"),
        ("DietaryVitaminD", .nutrizione, "g"),
        ("DietaryVitaminE", .nutrizione, "g"),
        ("DietaryVitaminK", .nutrizione, "g"),
        ("DietaryZinc", .nutrizione, "g"),
    ]

    /// (nome breve, gruppo, consegna immediata)
    private static let categories: [(String, DataGroup, Bool)] = [
        ("AppleStandHour", .attivita, false),
        ("AppleWalkingSteadinessEvent", .attivita, true),
        ("HighHeartRateEvent", .cuore, true),
        ("LowHeartRateEvent", .cuore, true),
        ("IrregularHeartRhythmEvent", .cuore, true),
        ("LowCardioFitnessEvent", .cuore, true),
        ("HypertensionEvent", .cuore, true),
        ("SleepAnalysis", .sonno, true),
        ("SleepApneaEvent", .sonno, true),
        ("EnvironmentalAudioExposureEvent", .udito, true),
        ("HeadphoneAudioExposureEvent", .udito, true),
        ("MindfulSession", .mindfulness, true),
        // Salute riproduttiva
        ("MenstrualFlow", .ciclo, false),
        ("IntermenstrualBleeding", .ciclo, false),
        ("InfrequentMenstrualCycles", .ciclo, false),
        ("IrregularMenstrualCycles", .ciclo, false),
        ("PersistentIntermenstrualBleeding", .ciclo, false),
        ("ProlongedMenstrualPeriods", .ciclo, false),
        ("CervicalMucusQuality", .ciclo, false),
        ("OvulationTestResult", .ciclo, false),
        ("PregnancyTestResult", .ciclo, false),
        ("ProgesteroneTestResult", .ciclo, false),
        ("SexualActivity", .ciclo, false),
        ("Contraceptive", .ciclo, false),
        ("Pregnancy", .ciclo, false),
        ("Lactation", .ciclo, false),
        ("BleedingAfterPregnancy", .ciclo, false),
        ("BleedingDuringPregnancy", .ciclo, false),
        // Igiene
        ("HandwashingEvent", .igiene, false),
        ("ToothbrushingEvent", .igiene, false),
        // Sintomi
        ("AbdominalCramps", .sintomi, false), ("Acne", .sintomi, false),
        ("AppetiteChanges", .sintomi, false), ("BladderIncontinence", .sintomi, false),
        ("Bloating", .sintomi, false), ("BreastPain", .sintomi, false),
        ("ChestTightnessOrPain", .sintomi, false), ("Chills", .sintomi, false),
        ("Constipation", .sintomi, false), ("Coughing", .sintomi, false),
        ("Diarrhea", .sintomi, false), ("Dizziness", .sintomi, false),
        ("DrySkin", .sintomi, false), ("Fainting", .sintomi, false),
        ("Fatigue", .sintomi, false), ("Fever", .sintomi, false),
        ("GeneralizedBodyAche", .sintomi, false), ("HairLoss", .sintomi, false),
        ("Headache", .sintomi, false), ("Heartburn", .sintomi, false),
        ("HotFlashes", .sintomi, false), ("LossOfSmell", .sintomi, false),
        ("LossOfTaste", .sintomi, false), ("LowerBackPain", .sintomi, false),
        ("MemoryLapse", .sintomi, false), ("MoodChanges", .sintomi, false),
        ("Nausea", .sintomi, false), ("NightSweats", .sintomi, false),
        ("PelvicPain", .sintomi, false), ("RapidPoundingOrFlutteringHeartbeat", .sintomi, false),
        ("RunnyNose", .sintomi, false), ("ShortnessOfBreath", .sintomi, false),
        ("SinusCongestion", .sintomi, false), ("SkippedHeartbeat", .sintomi, false),
        ("SleepChanges", .sintomi, false), ("SoreThroat", .sintomi, false),
        ("VaginalDryness", .sintomi, false), ("Vomiting", .sintomi, false),
        ("Wheezing", .sintomi, false),
    ]

    /// Tutte le voci conosciute (anche quelle non disponibili su questo iOS).
    static let allEntries: [CatalogEntry] = {
        var out: [CatalogEntry] = []
        for (name, group, unit) in quantities {
            out.append(CatalogEntry(identifier: q + name, group: group, kind: .quantity(unit: unit), immediate: false))
        }
        for (name, group, immediate) in categories {
            out.append(CatalogEntry(identifier: c + name, group: group, kind: .category, immediate: immediate))
        }
        out.append(CatalogEntry(identifier: "HKWorkoutTypeIdentifier", group: .allenamenti, kind: .workout, immediate: true))
        out.append(CatalogEntry(identifier: "HKDataTypeIdentifierElectrocardiogram", group: .ecg, kind: .electrocardiogram, immediate: true))
        out.append(CatalogEntry(identifier: "HKDataTypeIdentifierAudiogram", group: .udito, kind: .audiogram, immediate: false))
        out.append(CatalogEntry(identifier: "HKDataTypeIdentifierStateOfMind", group: .mindfulness, kind: .stateOfMind, immediate: true))
        out.append(CatalogEntry(identifier: HKCorrelationTypeIdentifier.bloodPressure.rawValue,
                                group: .cuore, kind: .correlation, immediate: false))
        return out
    }()

    /// Le voci realmente disponibili su questo dispositivo, con unità compatibili.
    static let availableEntries: [CatalogEntry] = allEntries.filter { entry in
        guard let type = entry.sampleType else { return false }
        if let qt = type as? HKQuantityType, let unit = entry.unit {
            return qt.is(compatibleWith: unit)
        }
        return true
    }

    static func entries(in groups: Set<DataGroup>) -> [CatalogEntry] {
        availableEntries.filter { groups.contains($0.group) }
    }

    static func entry(for identifier: String) -> CatalogEntry? {
        availableEntries.first { $0.identifier == identifier }
    }

    static func count(in group: DataGroup) -> Int {
        availableEntries.filter { $0.group == group }.count
    }

    /// Caratteristiche personali (lette una volta sola).
    static let characteristicTypes: Set<HKObjectType> = {
        let ids: [HKCharacteristicTypeIdentifier] = [
            .dateOfBirth, .biologicalSex, .bloodType, .fitzpatrickSkinType, .wheelchairUse, .activityMoveMode,
        ]
        return Set(ids.compactMap { HKObjectType.characteristicType(forIdentifier: $0) })
    }()

    /// I tipi da chiedere in lettura per i gruppi scelti. Le caratteristiche personali
    /// (data di nascita, sesso…) solo con il gruppo Corpo; il riepilogo degli anelli con Attività;
    /// i percorsi GPS solo con Allenamenti e solo se l'utente li ha accesi (spenti di serie).
    static func readTypes(groups: Set<DataGroup>, includeRoutes: Bool) -> Set<HKObjectType> {
        // Le correlazioni usano i permessi dei campioni contenuti. Non hanno
        // un'autorizzazione separata: chiediamo sistolica e diastolica già nel gruppo Cuore.
        var set = Set<HKObjectType>(entries(in: groups)
            .filter { $0.kind != .correlation }.compactMap(\.sampleType))
        if groups.contains(.corpo) { set.formUnion(characteristicTypes) }
        if groups.contains(.attivita) { set.insert(HKObjectType.activitySummaryType()) }
        if includeRoutes, groups.contains(.allenamenti) { set.insert(HKSeriesType.workoutRoute()) }
        return set
    }

    /// Numero di tipi del catalogo (tutti i gruppi) noti a questa versione di iOS.
    static var totalCount: Int { availableEntries.count }

    /// Le unità con caratteri speciali vengono costruite esplicitamente.
    static func makeUnit(_ s: String) -> HKUnit {
        switch s {
        case "count/min": return HKUnit.count().unitDivided(by: .minute())
        case "kcal/hr·kg": return HKUnit.kilocalorie().unitDivided(by: HKUnit.hour().unitMultiplied(by: .gramUnit(with: .kilo)))
        case "ml/kg·min": return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case "appleEffortScore": return HKUnit.appleEffortScore()
        case "dBASPL": return HKUnit.decibelAWeightedSoundPressureLevel()
        case "mg/dL": return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case "L/min": return HKUnit.liter().unitDivided(by: .minute())
        case "IU": return HKUnit.internationalUnit()
        case "%": return HKUnit.percent()
        default: return HKUnit(from: s)
        }
    }
}
