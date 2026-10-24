# Native HealthKit query constructor checks

Run on a Mac with macOS 26 or later and Xcode:

```sh
python3 tests/background/run.py
```

This compiles the production HealthCatalog and constructs real HealthKit queries.
It tests every available observer type individually and the combined production
selection, including the separately observed workout-route type. It also checks
the anchored-query constructors for the new sample types and vision prescriptions.

Vision prescriptions remain readable but cannot be passed to HKObserverQuery.
One isolated child process deliberately reproduces that native Objective-C
exception. Its SIGABRT is expected and verified; core dumps are disabled. This
regression could not be caught by the fake HealthKit constructors in the ordinary
sync state-machine tests.

The fixture never creates HKHealthStore, executes a query, requests authorization,
opens a device, reads health data, or sends network requests. Constructor success
does not establish read authorization, query-execution support on every iOS
version, or successful background delivery on a physical iPhone.
