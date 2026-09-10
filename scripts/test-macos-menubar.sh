#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/codex-auth-menubar-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cd "$test_dir"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  "$project_dir/native/menubar/Models.swift" "$project_dir/native/menubar/Store.swift" \
  "$project_dir/tests/menubar.test.swift" -o "$test_dir/menubar-tests" \
  -framework AppKit -framework SwiftUI
CODEX_HOME="$test_dir/codex" "$test_dir/menubar-tests"
