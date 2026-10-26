#!/bin/bash
# Real local 12B smoke against a synthetic text; does not modify the signed app.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 ]] || { echo 'Usage: bash tests/run_inference_0619.sh /path/to/translategemma-12b-it-Q4_K_M.gguf'; exit 2; }
CORE="${FL_TEST_CORE:-target/aarch64-apple-darwin/release/libfreelingo_core.a}"
mkdir -p .build/inference-smoke
ditto dist/FreeLingo.app/Contents/MacOS .build/inference-smoke
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 \
  tests/inference_0619.c "$CORE" -framework Security -framework SystemConfiguration \
  -liconv -lresolv -o .build/inference-smoke/qa-inference
.build/inference-smoke/qa-inference "$1"
