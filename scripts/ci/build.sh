#!/usr/bin/env bash
set -euo pipefail

# scripts/ci/build.sh: Compiles the native Rhizo binary
# Uses nimble build if available, otherwise direct nim compiler invocation.

NIM_BIN="${NIM_BIN:-nim}"
OUT_DIR="${OUT_DIR:-bin}"

echo "=== Compiling native Rhizo binary with ${NIM_BIN} ==="
mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}/rhizo" "${OUT_DIR}/rhizo.exe"

if command -v nimble >/dev/null 2>&1; then
  nimble build -y -d:release
else
  "${NIM_BIN}" c -d:release -o:"${OUT_DIR}/rhizo" src/rhizo.nim
fi

echo "=== Verifying compiled binary ==="
if [ -f "./${OUT_DIR}/rhizo.exe" ]; then
  "./${OUT_DIR}/rhizo.exe" --version || "./${OUT_DIR}/rhizo.exe" --help >/dev/null
  echo "=== Build succeeded: ${OUT_DIR}/rhizo.exe ==="
else
  "./${OUT_DIR}/rhizo" --version || "./${OUT_DIR}/rhizo" --help >/dev/null
  echo "=== Build succeeded: ${OUT_DIR}/rhizo ==="
fi
