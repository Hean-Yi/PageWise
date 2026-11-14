#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
crop_bin_dir="$(swift build --show-bin-path)"
mkdir -p .local
rg '/(PaperReaderKit|SwiftSoup)\.build/' "$crop_bin_dir/ReaderSmoke.product/Objects.LinkFileList" > .local/crop-audit-objects
swiftc -I "$crop_bin_dir/Modules" -I Sources/CSQLite scripts/FigureCropAudit.swift \
  @.local/crop-audit-objects -o .local/figure-crop-audit
.local/figure-crop-audit "$@"
