#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
swift build -c release -Xswiftc -enable-testing
build_dir="$(swift build -c release --show-bin-path)"
python3 - "$build_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
objects = [*root.glob('PaperReaderKit.build/*.o'), *root.glob('PaperReaderUI.build/*.o'), *root.glob('SwiftSoup.build/*.o')]
Path('.local/reading-performance-objects').write_text('\n'.join(str(path) for path in objects) + '\n')
PY
swiftc -O -parse-as-library -I "$build_dir/Modules" -I Sources/CSQLite \
  scripts/ReadingPerformance.swift @.local/reading-performance-objects -o .local/reading-performance-probe
.local/reading-performance-probe "${1:-.local/reading-performance}" "${2:-}"
