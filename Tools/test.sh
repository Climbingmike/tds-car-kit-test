#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH=/private/tmp/tds-carkit-native-cache/clang
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/tds-carkit-native-cache/swift
swift test -c release --disable-sandbox --package-path "$project_root" --scratch-path /private/tmp/tds-carkit-native-tests
