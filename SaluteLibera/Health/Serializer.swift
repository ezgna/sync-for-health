import CoreLocation
import CoreFoundation
import Foundation
import HealthKit

/// Converte gli oggetti HealthKit nei record del payload.
enum Serializer {
    static func source(_ s: HKSample) -> String { s.sourceRevision.source.name }

    static func provenance(_ s: HKSample) -> SampleProvenance {
        let revision = s.sourceRevision
        let os = revision.operatingSystemVersion
        var device: DeviceProvenance?
        if let d = s.device {
            device = DeviceProvenance(
                name: d.name, manufacturer: d.manufacturer, model: d.model,
                hardware_version: d.hardwareVersion, firmware_version: d.firmwareVersion,
                software_version: d.softwareVersion, local_identifier: d.localIdentifier,
                udi_device_identifier: d.udiDeviceIdentifier)
        }
        return SampleProvenance(
            bundle_id: revision.source.bundleIdentifier,
            source_version: revision.version,
            source_product_type: revision.productType,
            source_os_version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            device: device)
    }

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

    /// A differenza della mappa compatibile sopra, conserva i tipi e la struttura.
    static func typedMetadata(_ m: [String: Any]?) -> [String: MetadataValue]? {
        guard let m, !m.isEmpty else { return nil }
        return m.mapValues(typedMetadataValue)
    }

    static func typedMetadataValue(_ value: Any) -> MetadataValue {
        switch value {
        case is NSNull: return .null
        case let date as Date:
            return .object(["type": .string("date"), "value": .string(ISO.string(date)),
                            "seconds_since_reference_date": finiteNumber(date.timeIntervalSinceReferenceDate)])
        case let quantity as HKQuantity:
            var object: [String: MetadataValue] = ["type": .string("HKQuantity"),
                                                   "description": .string(quantity.description)]
            // HKQuantity has no public original-unit accessor. A secure archive
            // preserves the original object; canonical value/unit aids JSON users.
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: quantity, requiringSecureCoding: true) {
                object["archive_format"] = .string("NSKeyedArchiver.secureCoding")
                object["archive_base64"] = .string(data.base64EncodedString())
            } else {
                object["archive_status"] = .string("unavailable")
            }
            if let unit = metadataUnit(for: quantity) {
                object["value"] = finiteNumber(quantity.doubleValue(for: unit))
                object["unit"] = .string(unit.unitString)
                object["unit_representation"] = .string("canonical_conversion")
            }
            return .object(object)
        case let decimal as NSDecimalNumber:
            return .object(["type": .string("decimal"), "value": .string(decimal.stringValue)])
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let objc = String(cString: number.objCType)
            let numeric: MetadataValue
            if ["C", "S", "I", "L", "Q"].contains(objc) {
                numeric = .unsigned(number.uint64Value)
            } else if ["c", "s", "i", "l", "q"].contains(objc) {
                numeric = .integer(number.int64Value)
            } else {
                numeric = finiteNumber(number.doubleValue)
            }
            return .object(["type": .string("number"), "objc_type": .string(objc), "value": numeric])
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map(typedMetadataValue))
        case let dictionary as [String: Any]: return .object(dictionary.mapValues(typedMetadataValue))
        default:
            return .object(["type": .string(String(reflecting: type(of: value))),
                            "representation": .string("description_only"),
                            "description": .string(String(describing: value))])
        }
    }

    private static func finiteNumber(_ value: Double) -> MetadataValue {
        value.isFinite ? .number(value) : .object(["type": .string("non_finite_number"), "value": .string(String(value))])
    }

    private static func metadataUnit(for quantity: HKQuantity) -> HKUnit? {
        // Only construct units known valid by the app; unknown dimensions keep
        // the archived original rather than guessing by parsing description text.
        HealthCatalog.allEntries.compactMap(\.unit).first { quantity.is(compatibleWith: $0) }
    }

    static func quantity(_ s: HKQuantitySample, unit: HKUnit) -> QuantityRecord {
        var record = QuantityRecord(
            uuid: s.uuid.uuidString,
            tipo: s.quantityType.identifier,
            valore: s.quantity.doubleValue(for: unit),
            unita: unit.unitString,
            inizio: ISO.string(s.startDate),
            fine: ISO.string(s.endDate),
            fonte: source(s),
            metadati: metadata(s.metadata),
            provenienza: provenance(s),
            numero_quantita: s.count,
            metadati_typed: typedMetadata(s.metadata))
        if let discrete = s as? HKDiscreteQuantitySample {
            record.statistiche_discrete = DiscreteQuantityRecord(
                unita: unit.unitString, minimo: discrete.minimumQuantity.doubleValue(for: unit),
                media: discrete.averageQuantity.doubleValue(for: unit),
                massimo: discrete.maximumQuantity.doubleValue(for: unit),
                ultimo: discrete.mostRecentQuantity.doubleValue(for: unit),
                intervallo_ultimo: interval(discrete.mostRecentQuantityDateInterval))
        }
        return record
    }

    /// Il valore del campione può essere solo un riepilogo di molte misure.
    /// Per l'esportazione leggiamo anche i valori originali della serie.
    static func quantity(_ s: HKQuantitySample, unit: HKUnit, store: HKHealthStore) async throws -> QuantityRecord {
        try Task.checkCancellation()
        var record = quantity(s, unit: unit)
        guard s.count > 1 else { return record }
        let predicate = HKSamplePredicate.quantitySample(
            type: s.quantityType, predicate: HKQuery.predicateForObject(with: s.uuid))
        let descriptor = HKQuantitySeriesSampleQueryDescriptor(
            predicate: predicate, options: .orderByQuantitySampleStartDate)
        var points: [QuantitySeriesPoint] = []
        for try await entry in descriptor.results(for: store) {
            try Task.checkCancellation()
            points.append(QuantitySeriesPoint(
                valore: entry.quantity.doubleValue(for: unit),
                inizio: ISO.string(entry.dateInterval.start),
                fine: ISO.string(entry.dateInterval.end)))
        }
        try Task.checkCancellation()
        guard points.count == s.count else { throw SerializationError.incompleteQuantitySeries }
        record.serie = points
        return record
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
            metadati: metadata(s.metadata),
            provenienza: provenance(s),
            metadati_typed: typedMetadata(s.metadata))
    }

    static func correlation(_ s: HKCorrelation) -> CorrelationRecord {
        CorrelationRecord(
            uuid: s.uuid.uuidString, tipo: s.correlationType.identifier,
            inizio: ISO.string(s.startDate), fine: ISO.string(s.endDate), fonte: source(s),
            membri: s.objects.map { CorrelationMember(uuid: $0.uuid.uuidString, tipo: $0.sampleType.identifier) }
                .sorted { $0.uuid < $1.uuid },
            metadati: metadata(s.metadata), provenienza: provenance(s), metadati_typed: typedMetadata(s.metadata))
    }

    /// ECG con riepilogo e tracciato completo (derivazione simile a DI, in µV).
    /// Le misure vengono lette per intero prima di costruire il record; un ECG alla volta.
    static func electrocardiogram(_ e: HKElectrocardiogram, store: HKHealthStore) async throws -> ECGRecord {
        var record = electrocardiogramSummary(e)
        record.frequenza_hz = e.samplingFrequency?.doubleValue(for: .hertz())
        let waveform = try await waveform(of: e, store: store)
        if !waveform.values.isEmpty {
            record.unita_tracciato = "µV"
            record.tracciato = waveform.values
            record.tempi_tracciato_s = waveform.offsets
        }
        return record
    }

    /// Riepilogo per il grafico locale; l'esportazione usa waveform per mantenere anche i tempi.
    static func voltages(of e: HKElectrocardiogram, store: HKHealthStore) async throws -> [Double] {
        try await waveform(of: e, store: store).values
    }

    /// Valori e offset temporali HealthKit, senza arrotondamenti o tempi ricostruiti.
    static func waveform(of e: HKElectrocardiogram, store: HKHealthStore) async throws -> (values: [Double], offsets: [Double]) {
        try Task.checkCancellation()
        let microvolt = HKUnit.voltUnit(with: .micro)
        var values: [Double] = []
        var offsets: [Double] = []
        values.reserveCapacity(max(e.numberOfVoltageMeasurements, 0))
        offsets.reserveCapacity(max(e.numberOfVoltageMeasurements, 0))
        for try await measurement in HKElectrocardiogramQueryDescriptor(e).results(for: store) {
            try Task.checkCancellation()
            guard let q = measurement.quantity(for: .appleWatchSimilarToLeadI) else { continue }
            values.append(q.doubleValue(for: microvolt))
            offsets.append(measurement.timeSinceSampleStart)
        }
        try Task.checkCancellation()
        guard values.count == e.numberOfVoltageMeasurements else { throw SerializationError.incompleteECG }
        return (values, offsets)
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
            fonte: source(e),
            metadati: metadata(e.metadata),
            provenienza: provenance(e),
            numero_misure: e.numberOfVoltageMeasurements,
            metadati_typed: typedMetadata(e.metadata))
    }

    static func audiogram(_ a: HKAudiogramSample) -> AudiogramRecord {
        let hz = HKUnit.hertz()
        let dbhl = HKUnit.decibelHearingLevel()
        let points = a.sensitivityPoints.map { p in
            var point = AudiogramPoint(frequenza_hz: p.frequency.doubleValue(for: hz))
            point.test = p.tests.map { test in
                AudiogramTest(
                    tipo_raw: test.type.rawValue, lato_raw: test.side.rawValue,
                    masked: test.masked, sensibilita_dbhl: test.sensitivity.doubleValue(for: dbhl),
                    limite_inferiore_dbhl: test.clampingRange?.lowerBound?.doubleValue(for: dbhl),
                    limite_superiore_dbhl: test.clampingRange?.upperBound?.doubleValue(for: dbhl))
            }
            for test in p.tests where test.type == .air && !test.masked {
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
                               fine: ISO.string(a.endDate), fonte: source(a), punti: points,
                               metadati: metadata(a.metadata), provenienza: provenance(a), metadati_typed: typedMetadata(a.metadata))
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
            fonte: source(s),
            fine: ISO.string(s.endDate),
            tipo_raw: s.kind.rawValue,
            classificazione_raw: s.valenceClassification.rawValue,
            etichette_raw: s.labels.map(\.rawValue),
            associazioni_raw: s.associations.map(\.rawValue),
            metadati: metadata(s.metadata),
            provenienza: provenance(s),
            metadati_typed: typedMetadata(s.metadata))
    }

    static func interval(_ value: DateInterval) -> RecordInterval {
        RecordInterval(inizio: ISO.string(value.start), fine: ISO.string(value.end))
    }

    static func workoutEvent(_ event: HKWorkoutEvent) -> WorkoutEventRecord {
        WorkoutEventRecord(tipo_raw: event.type.rawValue,
                           inizio: ISO.string(event.dateInterval.start), fine: ISO.string(event.dateInterval.end),
                           metadati: metadata(event.metadata), metadati_typed: typedMetadata(event.metadata))
    }

    static func workoutConfiguration(_ configuration: HKWorkoutConfiguration) -> WorkoutConfigurationRecord {
        WorkoutConfigurationRecord(attivita: activityName(configuration.activityType),
                                   attivita_raw: configuration.activityType.rawValue,
                                   luogo_raw: configuration.locationType.rawValue,
                                   luogo_nuoto_raw: configuration.swimmingLocationType.rawValue,
                                   lunghezza_vasca_m: configuration.lapLength?.doubleValue(for: .meter()))
    }

    static func workoutActivity(_ activity: HKWorkoutActivity, units: [HKQuantityType: HKUnit]) -> WorkoutActivityRecord {
        WorkoutActivityRecord(uuid: activity.uuid.uuidString,
                              configurazione: workoutConfiguration(activity.workoutConfiguration),
                              inizio: ISO.string(activity.startDate), fine: activity.endDate.map(ISO.string),
                              durata_s: activity.duration, eventi: activity.workoutEvents.map(workoutEvent),
                              statistiche: workoutStatistics(activity.allStatistics, units: units),
                              metadati: metadata(activity.metadata), metadati_typed: typedMetadata(activity.metadata))
    }

    /// Statistics for unknown types must remain in the archive. If a convertible
    /// unit cannot be obtained, preserve the original HKQuantity objects explicitly.
    static func workoutStatistics(_ statistics: [HKQuantityType: HKStatistics],
                                  units: [HKQuantityType: HKUnit]) -> [String: WorkoutStat] {
        var output: [String: WorkoutStat] = [:]
        for (type, stat) in statistics {
            let unit = units[type]
            let values = ["somma": stat.sumQuantity(), "media": stat.averageQuantity(),
                          "minimo": stat.minimumQuantity(), "massimo": stat.maximumQuantity(),
                          "ultimo": stat.mostRecentQuantity()].compactMapValues { $0 }
            var record = WorkoutStat(unita: unit?.unitString ?? "")
            record.inizio = ISO.string(stat.startDate)
            record.fine = ISO.string(stat.endDate)
            record.intervallo_ultimo = stat.mostRecentQuantityDateInterval().map(interval)
            record.durata_s = stat.duration()?.doubleValue(for: .second())
            if let unit, values.values.allSatisfy({ $0.is(compatibleWith: unit) }) {
                record.somma = values["somma"]?.doubleValue(for: unit)
                record.media = values["media"]?.doubleValue(for: unit)
                record.minimo = values["minimo"]?.doubleValue(for: unit)
                record.massimo = values["massimo"]?.doubleValue(for: unit)
                record.ultimo = values["ultimo"]?.doubleValue(for: unit)
            } else {
                record.conversione = unit == nil ? "unit_unavailable" : "incompatible_quantity"
                record.quantita_originali = values.mapValues(typedMetadataValue)
            }
            output[type.identifier] = record
        }
        return output
    }

    private static func workoutUnits(_ types: Set<HKQuantityType>, store: HKHealthStore) async throws -> [HKQuantityType: HKUnit] {
        var units: [HKQuantityType: HKUnit] = [:]
        var unknown: Set<HKQuantityType> = []
        for type in types {
            if let unit = HealthCatalog.entry(for: type.identifier)?.unit, type.is(compatibleWith: unit) {
                units[type] = unit
            } else {
                unknown.insert(type)
            }
        }
        if !unknown.isEmpty {
            try Task.checkCancellation()
            for (type, unit) in try await store.preferredUnits(for: unknown) where type.is(compatibleWith: unit) {
                units[type] = unit
            }
        }
        return units
    }

    /// Pure conversion shared by live export and synthetic contract tests.
    static func workoutRecord(_ w: HKWorkout, units: [HKQuantityType: HKUnit]) -> WorkoutRecord {
        let stats = workoutStatistics(w.allStatistics, units: units)
        // Summary fields always use their declared units, regardless of preferred units.
        let energyType = HKQuantityType(.activeEnergyBurned)
        let energy = w.allStatistics[energyType]?.sumQuantity()?.doubleValue(for: .kilocalorie())
        var distances: [Double] = []
        for (type, stat) in w.allStatistics where type.identifier.hasPrefix("HKQuantityTypeIdentifierDistance")
            && type.is(compatibleWith: .meter()) {
            if let total = stat.sumQuantity() { distances.append(total.doubleValue(for: .meter())) }
        }
        return WorkoutRecord(
            uuid: w.uuid.uuidString, attivita: activityName(w.workoutActivityType),
            inizio: ISO.string(w.startDate), fine: ISO.string(w.endDate), durata_s: w.duration,
            energia_kcal: energy, distanza_m: distances.count == 1 ? distances[0] : nil,
            fonte: source(w), statistiche: stats.isEmpty ? nil : stats,
            metadati: metadata(w.metadata), provenienza: provenance(w),
            metadati_typed: typedMetadata(w.metadata), attivita_raw: w.workoutActivityType.rawValue,
            eventi: w.workoutEvents.map { $0.map(workoutEvent) },
            attivita_dettaglio: w.workoutActivities.map { workoutActivity($0, units: units) })
    }

    /// Allenamento con eventi e vere suddivisioni multisport, non ricostruite dagli orari.
    static func workout(_ w: HKWorkout, store: HKHealthStore, includeRoute: Bool) async throws -> WorkoutRecord {
        try Task.checkCancellation()
        var allTypes = Set(w.allStatistics.keys)
        for activity in w.workoutActivities { allTypes.formUnion(activity.allStatistics.keys) }
        let units = try await workoutUnits(allTypes, store: store)
        var record = workoutRecord(w, units: units)
        // Only query quantity types actually represented in this workout's statistics.
        // One multi-type paged query avoids a request per each of the app's 100+ types.
        record.ambito_campioni_associati = allTypes.map(\.identifier).sorted()
        record.campioni_associati = try await associatedSamples(for: w, types: allTypes, store: store)
        if #available(iOS 18.0, macOS 15.0, *) {
            record.relazioni_sforzo = try await effortRelationships(for: w, store: store)
        }
        if includeRoute {
            // [] means the API returned no readable route. HealthKit does not
            // distinguish missing data from denied permission.
            record.percorsi = try await routes(for: w, store: store)
        }
        try Task.checkCancellation()
        return record
    }

    private static func associatedSamples(for workout: HKWorkout, types: Set<HKQuantityType>,
                                          store: HKHealthStore) async throws -> [WorkoutSampleReference] {
        guard !types.isEmpty else { return [] }
        let predicate = HKQuery.predicateForObjects(from: workout)
        let predicates: [HKSamplePredicate<HKSample>] = types.sorted { $0.identifier < $1.identifier }
            .map { .sample(type: $0, predicate: predicate) }
        var anchor: HKQueryAnchor?
        var references: [String: WorkoutSampleReference] = [:]
        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(predicates: predicates, anchor: anchor, limit: 500)
            let page = try await query.result(for: store)
            for sample in page.addedSamples {
                references[sample.uuid.uuidString] = WorkoutSampleReference(uuid: sample.uuid.uuidString,
                                                                          tipo: sample.sampleType.identifier)
            }
            for deleted in page.deletedObjects { references.removeValue(forKey: deleted.uuid.uuidString) }
            anchor = page.newAnchor
            if page.addedSamples.count + page.deletedObjects.count < 500 { break }
        }
        return references.values.sorted { $0.uuid < $1.uuid }
    }

    @available(iOS 18.0, macOS 15.0, *)
    private static func effortRelationships(for workout: HKWorkout, store: HKHealthStore) async throws -> [WorkoutEffortRelationshipRecord] {
        try Task.checkCancellation()
        let query = HKWorkoutEffortRelationshipQueryDescriptor(
            predicate: HKQuery.predicateForObject(with: workout.uuid), anchor: nil, option: .default)
        let result = try await query.result(for: store)
        try Task.checkCancellation()
        return result.relationships.map { relationship in
            WorkoutEffortRelationshipRecord(
                workout_uuid: relationship.workout.uuid.uuidString,
                attivita_uuid: relationship.activity?.uuid.uuidString,
                campioni: relationship.samples?.map {
                    WorkoutSampleReference(uuid: $0.uuid.uuidString, tipo: $0.sampleType.identifier)
                }.sorted { $0.uuid < $1.uuid })
        }.sorted { ($0.attivita_uuid ?? "", $0.workout_uuid) < ($1.attivita_uuid ?? "", $1.workout_uuid) }
    }

    /// Each HKWorkoutRoute stays separate, with source, device and metadata.
    static func routes(for workout: HKWorkout, store: HKHealthStore) async throws -> [WorkoutRouteRecord] {
        try Task.checkCancellation()
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let routes = try await descriptor.result(for: store)
        var records: [WorkoutRouteRecord] = []
        for route in routes {
            try Task.checkCancellation()
            var points: [RoutePoint] = []
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                try Task.checkCancellation()
                points.append(RoutePoint(
                    lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                    alt: location.altitude, t: ISO.string(location.timestamp),
                    precisione_orizzontale_m: location.horizontalAccuracy,
                    precisione_verticale_m: location.verticalAccuracy,
                    velocita_m_s: location.speed, precisione_velocita_m_s: location.speedAccuracy,
                    direzione_gradi: location.course, precisione_direzione_gradi: location.courseAccuracy))
            }
            guard points.count == route.count else { throw SerializationError.incompleteRoute }
            records.append(WorkoutRouteRecord(uuid: route.uuid.uuidString, inizio: ISO.string(route.startDate),
                                              fine: ISO.string(route.endDate), fonte: source(route), punti: points,
                                              provenienza: provenance(route), metadati: metadata(route.metadata),
                                              metadati_typed: typedMetadata(route.metadata)))
        }
        try Task.checkCancellation()
        return records
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

enum SerializationError: Error, LocalizedError {
    case incompleteQuantitySeries
    case incompleteECG
    case incompleteRoute

    var errorDescription: String? {
        switch self {
        case .incompleteQuantitySeries: "HealthKit non ha restituito tutta la serie quantitativa. Riprova la sincronizzazione."
        case .incompleteECG: "HealthKit non ha restituito tutto il tracciato ECG. Riprova la sincronizzazione."
        case .incompleteRoute: "HealthKit non ha restituito tutti i punti del percorso. Riprova la sincronizzazione."
        }
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
