#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/health-serialization-tests.XXXXXX")
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM
xcrun swiftc -target "$(uname -m)-apple-macos26.0" \
  "$repo_root/SaluteLibera/Model/Payload.swift" \
  "$repo_root/SaluteLibera/Health/HealthCatalog.swift" \
  "$repo_root/SaluteLibera/Health/Serializer.swift" \
  "$repo_root/tests/serialization/SerializationContractTests.swift" \
  -o "$scratch_dir/serialization-tests"
"$scratch_dir/serialization-tests"
