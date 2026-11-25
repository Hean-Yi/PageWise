#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
work_dir=$(mktemp -d "$PWD/.local/reading-probe.XXXXXXXX")
trap 'rm -r -- "$work_dir"' EXIT
swift build -c release --jobs 2 -Xswiftc -enable-testing
build_dir="$(swift build -c release --show-bin-path)"

# ReaderSmoke already links the complete PaperReaderKit dependency graph, including the tokenizer's C++ objects.
# Add the UI objects and substitute this probe's main for the smoke-test executable's entry point.
python3 - "$build_dir" "$work_dir/objects" <<'PY'
from pathlib import Path
import json
import sys

products, response = map(Path, sys.argv[1:])
objects = (products / 'ReaderSmoke.product/Objects.LinkFileList').read_text().splitlines()
objects = [path for path in objects if '/ReaderSmoke.build/' not in path]
objects += [str(path) for path in (products / 'PaperReaderUI.build').glob('*.o')]
response.write_text('\n'.join(json.dumps(path.strip('"'), ensure_ascii=False) for path in objects) + '\n')
PY
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos15.0" \
  -I "$build_dir/Modules" -I Sources/CSQLite -Xcc "-fmodule-map-file=$build_dir/C_sentencepiece.build/module.modulemap" \
  scripts/ReadingPerformance.swift @"$work_dir/objects" -lc++ -o "$work_dir/probe"
"$work_dir/probe" "${1:-.local/reading-performance}" "${2:-}"
