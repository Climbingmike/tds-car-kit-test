#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/tds-carkit-listener.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
export CLANG_MODULE_CACHE_PATH=/private/tmp/tds-carkit-native-cache/clang
xcrun clang -c "$project_root/Sources/CTDSCarKitCrypto/TDSCarKitCrypto.c" \
  -I "$project_root/Sources/CTDSCarKitCrypto/include" -o "$work_dir/crypto.o"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -module-cache-path /private/tmp/tds-carkit-native-cache/swift \
  -import-objc-header "$project_root/Sources/CTDSCarKitCrypto/include/TDSCarKitCrypto.h" \
  "$project_root"/Sources/TDSCarKitCore/*.swift \
  "$project_root"/Sources/TDSCarKitCore/Vendor/BigInt/*.swift \
  "$project_root/App/ReceiverConfiguration.swift" "$project_root/App/NativeReceiver.swift" \
  "$project_root/App/AirPlayCredentials.swift" \
  "$project_root/App/CarPlayInfo.swift" "$project_root/App/CarPlayMediaSession.swift" "$project_root/App/MediaSockets.swift" \
  "$project_root/App/CarPlayAudio.swift" \
  "$project_root/Tools/ListenerSmoke.swift" "$work_dir/crypto.o" -o "$work_dir/listener-test"
"$work_dir/listener-test" "$project_root/.local/Identity"
