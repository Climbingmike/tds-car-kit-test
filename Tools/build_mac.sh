#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${TDS_CAR_KIT_BUILD_DIR:-/private/tmp/tds-carkit-native-build}"
python3 "$project_root/Tools/generate_project.py"
xcodebuild -project "$project_root/TDSCarKit.xcodeproj" -scheme TDSCarKit \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$build_root" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
app_path="$build_root/Build/Products/Debug-maccatalyst/TDSCarKit.app"
codesign --verify --deep --strict "$app_path"
if [[ "${1:-}" == "--open" ]]; then open "$app_path"; fi
printf '\nBuilt app: %s\n' "$app_path"
