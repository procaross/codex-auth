#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/panel-dismissal-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cd "$test_dir"
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/module-cache" \
  "$project_dir/native/menubar/PanelDismissal.swift" "$project_dir/tests/PanelDismissalTests.swift" \
  -o "$test_dir/panel-dismissal-tests"
"$test_dir/panel-dismissal-tests"
