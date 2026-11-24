#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
products=$(mktemp -d "$PWD/.local/check-products.XXXXXXXX")
trap 'rm -r -- "$products"' EXIT

xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests App
swift test --jobs 3 --no-parallel
swift run --skip-build ReaderSmoke "$products/smoke"
xcodebuild -quiet -jobs 3 -project PaperReader.xcodeproj -scheme PaperReader \
  -destination 'generic/platform=macOS' -derivedDataPath .local/build-mac \
  CONFIGURATION_BUILD_DIR="$products/mac" ONLY_ACTIVE_ARCH=YES "ARCHS=$(uname -m)" CODE_SIGN_IDENTITY=- build
rm -r -- "$products/mac"
xcodebuild -quiet -jobs 3 -project PaperReader.xcodeproj -scheme PaperReader-iPad \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .local/build-ipad \
  CONFIGURATION_BUILD_DIR="$products/ipad" CODE_SIGNING_ALLOWED=NO build
