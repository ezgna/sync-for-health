# Offline contract tests

Run from the repository on macOS with Xcode installed:

```sh
python3 tests/settings/run.py
python3 tests/sync_engine_contract.py
sh tests/transport/run.sh
sh tests/serialization/run.sh
```

The settings runner compiles the production settings model with an in-memory
Keychain adapter and a separate temporary UserDefaults suite. It checks atomic
connection changes, secure-save failure, revision cancellation, destination
namespaces, group/route backfill, restart, and explicit full replay. It never
accesses the real Keychain.

The runner compiles the current production `SyncCoordinator`, `SyncJob`, `Batch`,
`Payload`, `AnchorStore`, `HealthBackground`, and local demo animation against
fake HealthKit and HTTP adapters. The fake HTTP adapter is MainActor-isolated,
including suspended uploads inspected by the test driver.
It only uses temporary files and synthetic samples. No iPhone, user preferences,
network endpoint, credentials, real health data, Simulator, or Apple account is
accessed. On macOS the iOS-only file-protection write option is omitted in the
fixture; production iOS source retains it.

Covered contracts include bounded historical/deletion pagination, empty tail
pages, acknowledged-page restart, destination isolation, cancellation after a
settings change, byte-split replay, oversized sample failure without skipping,
checkpoint failure/retry, changed characteristics, late/deleted routes, persisted
route reconciliation progress, one-workout GPS posts, real disk-write failures,
corrupt cursor files, and observer restart ordering with explicitly delayed
HealthKit completion callbacks.

Also covered are new-settings requests which arrive during cancellation, delayed
settings notifications, and demo mode's exclusion from real HTTP, HealthKit,
cursors, completion flags, and success logs. The fixture replaces UserDefaults
with an in-memory dictionary.

To check fixture concurrency on macOS:

```sh
SYNC_CONTRACT_SWIFT_FLAGS=-sanitize=thread python3 tests/sync_engine_contract.py
```

`SYNC_CONTRACT_KEEP_DIR` optionally retains the compiled binary and extracted
sources. A failed binary run always preserves them in the work directory (or
`SYNC_CONTRACT_FAILURE_DIR`) for diagnosis.

These tests verify the sync state machine. They do not establish actual iOS
HealthKit permissions, background delivery timing, signing/provisioning, or
end-to-end operation with a physical iPhone. Run the unsigned iOS build separately
and complete physical-device validation before relying on automatic collection.
