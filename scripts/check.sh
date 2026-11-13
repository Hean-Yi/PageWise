#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests App
swift test
swift run ReaderSmoke .local/smoke
xcodebuild -quiet -project PaperReader.xcodeproj -scheme PaperReader \
  -destination 'platform=macOS' -derivedDataPath .local/build-mac CODE_SIGN_IDENTITY=- build
xcodebuild -quiet -project PaperReader.xcodeproj -scheme PaperReader-iPad \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .local/build-ipad CODE_SIGNING_ALLOWED=NO build
