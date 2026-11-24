#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -quiet -project PaperReader.xcodeproj -scheme PaperReader \
  -destination 'platform=macOS' -derivedDataPath .local/build-mac CODE_SIGN_IDENTITY=- build
open .local/build-mac/Build/Products/Debug/PageWise.app
