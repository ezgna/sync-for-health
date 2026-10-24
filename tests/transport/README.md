# Transport contract tests

Run on macOS with the Xcode command-line tools:

```sh
./tests/transport/run.sh
```

The tests compile the **production Uploader.swift and DiagLog.swift** with Swift 6
strict concurrency and warnings treated as errors. A synthetic URLProtocol handles
all requests, including HTTPS requests, so the tests make **no external network
connection**. Payload IDs, measurements and credentials are synthetic. The stubs
do not read the app's UserDefaults, Keychain or HealthKit. No diagnostic file is
created: network request logging is disabled and the diagnostic consent test exits
before accessing the log directory.

Coverage includes protocol-2 health/probe/diagnostic acknowledgements, gzip hashes,
wrong batch/hash/kind/protocol, uncommitted/incomplete ACKs, HTML200, 202, redirects,
ACK byte limits, response-body/error-description redaction, cancelled requests,
HTTPS-only destinations, query/userinfo/fragment rejection, token trimming and
header newline rejection, diagnostics opt-in and cache/cookie/credential isolation.
The redirect delegate is invoked directly for same-host and cross-host redirects;
no public redirect endpoint is used.

These are transport contract tests, not proof of iPhone background delivery or
long-term on-device operation.
