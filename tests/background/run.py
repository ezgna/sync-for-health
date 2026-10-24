#!/usr/bin/env python3
"""Exercise actual HealthKit query validation without opening a health store.

The vision observer is intentionally constructed in one isolated subprocess to
reproduce the native exception that the Swift-only mock could not detect.
No authorization request, database query, network request, or device is used.
"""
from pathlib import Path
import json
import platform
import resource
import signal
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
VISION = "HKVisionPrescriptionTypeIdentifier"
ROUTE = "HKWorkoutRouteTypeIdentifier"
CORRELATIONS = {"HKCorrelationTypeIdentifierBloodPressure", "HKCorrelationTypeIdentifierFood"}
NEW_SAMPLE_TYPES = {
    "HKDataTypeIdentifierHeartbeatSeries",
    "HKScoredAssessmentTypeIdentifierGAD7",
    "HKScoredAssessmentTypeIdentifierPHQ9",
    "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent",
}


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    # The deliberate child SIGABRT must never leave a core dump containing data.
    # The fixture itself contains only public type identifiers.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="health-native-query-contract-") as temporary:
        binary = Path(temporary) / "native-query-constructors"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            "-target", f"{platform.machine()}-apple-macos26.0",
            str(ROOT / "SaluteLibera/Health/HealthCatalog.swift"),
            str(ROOT / "tests/background/NativeQueryConstructors.swift"),
            "-o", str(binary),
        ], check=True)

        def invoke(*arguments, succeeds=True):
            completed = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=15)
            if succeeds:
                check(completed.returncode == 0,
                      f"Native HealthKit constructor failed for {arguments}: {completed.stderr}")
            return completed

        inventory = json.loads(invoke("inventory").stdout)
        by_id = {entry["identifier"]: entry for entry in inventory}
        check(VISION in by_id, "Vision prescriptions must remain in the readable catalog")
        check(by_id[VISION]["can_observe"] is False,
              "Vision prescriptions must be excluded from background observer registration")
        for identifier in CORRELATIONS:
            check(by_id[identifier]["can_observe"] is False,
                  f"Correlation type is not a background observer target: {identifier}")
        check(NEW_SAMPLE_TYPES.issubset(by_id), "The new readable sample types must be tested")
        for identifier in NEW_SAMPLE_TYPES:
            check(by_id[identifier]["can_observe"] is True,
                  f"A supported new observer type was unexpectedly removed: {identifier}")

        observed = [row["identifier"] for row in inventory if row["can_observe"]]
        for identifier in observed + [ROUTE]:
            invoke("observer", identifier)
        invoke("combined")

        # Reproduce the actual native failure in isolation. Swift do/catch
        # cannot catch this Objective-C exception, so it must never be sent to
        # production's HKObserverQuery constructor.
        unsupported = invoke("observer", VISION, succeeds=False)
        check(unsupported.returncode == -signal.SIGABRT,
              "Expected the isolated vision observer to raise native SIGABRT")
        check("HKQueryValidationFailureException" in unsupported.stderr
              and f"unsupported type {VISION}" in unsupported.stderr,
              "The native failure did not reproduce the reported HealthKit exception")

        # The observer restriction does not remove the independent anchored
        # read path. This remains a constructor test, without executing a query.
        for identifier in sorted(NEW_SAMPLE_TYPES | {VISION}):
            invoke("anchored", identifier)

        print(json.dumps({
            "available_catalog_types": len(inventory),
            "native_observer_types_checked": len(observed) + 1,
            "combined_production_observer_constructor": "passed",
            "vision_native_observer_exception": "reproduced_in_isolated_child",
            "vision_remains_readable": True,
            "new_types_and_vision_anchored_constructors": "passed",
            "health_store_created": False,
            "health_query_executed": False,
        }, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
