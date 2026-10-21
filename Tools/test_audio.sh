#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/tds-carkit-audio.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
python3 - "$work_dir" <<'PY'
import math, struct, sys, wave
from pathlib import Path
for rate in (44100,48000):
    with wave.open(str(Path(sys.argv[1]) / f'{rate}.wav'), 'wb') as f:
        f.setnchannels(2); f.setsampwidth(2); f.setframerate(rate)
        f.writeframes(b''.join(struct.pack('<hh', int(16384*math.sin(2*math.pi*440*i/rate)), int(8192*math.sin(2*math.pi*880*i/rate))) for i in range(rate)))
PY
for rate in 44100 48000; do
  afconvert -f adts -d aac -b 192000 "$work_dir/$rate.wav" "$work_dir/$rate.aac"
done
export CLANG_MODULE_CACHE_PATH=/private/tmp/tds-carkit-native-cache/clang
xcrun clang -c "$project_root/Sources/CTDSCarKitCrypto/TDSCarKitCrypto.c" \
  -I "$project_root/Sources/CTDSCarKitCrypto/include" -o "$work_dir/crypto.o"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -module-cache-path /private/tmp/tds-carkit-native-cache/swift \
  -import-objc-header "$project_root/Sources/CTDSCarKitCrypto/include/TDSCarKitCrypto.h" \
  "$project_root"/Sources/TDSCarKitCore/*.swift \
  "$project_root"/Sources/TDSCarKitCore/Vendor/BigInt/*.swift \
  "$project_root/App/CarPlayAudio.swift" "$project_root/Tools/AudioDecodeSmoke.swift" \
  "$work_dir/crypto.o" -o "$work_dir/audio-test"
"$work_dir/audio-test" "$work_dir"
