#!/bin/bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homecast-relay-tests.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT

cat "$app_dir/Tests/RelayWebSocketTests/LogStub.swift" \
    "$app_dir/Sources/Server/RelayWebSocketBridge.swift" \
    "$app_dir/Tests/RelayWebSocketTests/FailureCleanup.swift" > "$task_test_dir/main.swift"
xcrun swiftc -swift-version 5 "$task_test_dir/main.swift" -o "$task_test_dir/relay-tests"
"$task_test_dir/relay-tests"
