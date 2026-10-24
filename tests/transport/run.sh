#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/sfh-transport-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
cd "$project_dir"
xcrun swiftc -D TRANSPORT_CONTRACT_TESTS -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    SaluteLibera/Sync/Uploader.swift SaluteLibera/Model/DiagLog.swift \
    tests/transport/Support.swift tests/transport/TransportContractTests.swift \
    -o "$build_dir/transport-contract-tests"
"$build_dir/transport-contract-tests"
