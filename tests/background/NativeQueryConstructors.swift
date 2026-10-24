import Foundation
import HealthKit

/// Real HealthKit constructors only: no HKHealthStore is created and no query
/// is executed. Each unsupported constructor runs in its own child process.
@main
struct NativeQueryConstructors {
    enum Failure: Error { case invalidArguments, unknownIdentifier(String) }

    static func sampleType(_ identifier: String) throws -> HKSampleType {
        if identifier == HKSeriesType.workoutRoute().identifier { return HKSeriesType.workoutRoute() }
        guard let type = HealthCatalog.availableEntries.first(where: { $0.identifier == identifier })?.sampleType else {
            throw Failure.unknownIdentifier(identifier)
        }
        return type
    }

    static func observer(_ types: [HKSampleType]) {
        let descriptors = types.map { HKQueryDescriptor(sampleType: $0, predicate: nil) }
        let query = HKObserverQuery(queryDescriptors: descriptors) { _, _, completed, _ in completed() }
        withExtendedLifetime(query) {}
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else { throw Failure.invalidArguments }
        switch mode {
        case "inventory":
            let entries = HealthCatalog.availableEntries
            let rows = entries.map { entry in
                ["identifier": entry.identifier, "can_observe": entry.canObserve] as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        case "combined":
            // This is exactly the production filter, with the separately
            // observed workout-route type added when the GPS switch is enabled.
            var types = HealthCatalog.entries(in: Set(DataGroup.allCases))
                .filter(\.canObserve).compactMap(\.sampleType)
            types.append(HKSeriesType.workoutRoute())
            observer(types)
            print("OK combined \(types.count)")
        case "observer", "anchored":
            guard arguments.count == 2 else { throw Failure.invalidArguments }
            let type = try sampleType(arguments[1])
            if mode == "observer" {
                observer([type])
            } else {
                let descriptor = HKQueryDescriptor(sampleType: type, predicate: nil)
                let query = HKAnchoredObjectQuery(queryDescriptors: [descriptor], anchor: nil, limit: 1) {
                    _, _, _, _, _ in
                }
                withExtendedLifetime(query) {}
            }
            print("OK \(mode) \(type.identifier)")
        default:
            throw Failure.invalidArguments
        }
    }
}
