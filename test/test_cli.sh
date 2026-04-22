#!/usr/bin/env bash
# Smoke tests for prep_drs.sh CLI behavior.
# These tests DO NOT require nanopore tools, GPU, or real data.
# They verify argument parsing, input validation, and library syntax.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
SCRIPT="${ROOT}/prep_drs.sh"

PASSED=0
FAILED=0
FAIL_LOG=()

assert_exit_code() {
  local desc="$1"
  local expected="$2"
  shift 2
  local output actual
  output=$("$@" 2>&1 </dev/null || true)
  actual=$?
  # The above sets actual to the pipe's exit; re-run properly:
  "$@" >/dev/null 2>&1 </dev/null
  actual=$?
  if [[ ${actual} -eq ${expected} ]]; then
    echo "  PASS: ${desc}"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: ${desc} (expected ${expected}, got ${actual})"
    FAIL_LOG+=("${desc}: expected ${expected}, got ${actual}")
    FAILED=$((FAILED + 1))
  fi
}

assert_output_contains() {
  local desc="$1"
  local needle="$2"
  shift 2
  local output
  output=$("$@" 2>&1 </dev/null || true)
  if echo "${output}" | grep -q -- "${needle}"; then
    echo "  PASS: ${desc}"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: ${desc} (output missing '${needle}')"
    FAIL_LOG+=("${desc}: output did not contain '${needle}'")
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Syntax checks ==="
for f in prep_drs.sh lib/utils.sh lib/basecall.sh lib/signal_convert.sh; do
  if bash -n "${ROOT}/${f}" 2>/dev/null; then
    echo "  PASS: syntax ${f}"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: syntax ${f}"
    FAIL_LOG+=("syntax ${f}")
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== --help ==="
assert_exit_code "--help exits 0" 0 "${SCRIPT}" --help
assert_output_contains "--help prints 'Usage:'" "Usage:" "${SCRIPT}" --help
assert_output_contains "--help lists --sample" -- "--sample" "${SCRIPT}" --help

echo ""
echo "=== Argument validation ==="
assert_exit_code "no args exits 1" 1 "${SCRIPT}"
assert_exit_code "missing --input exits 1" 1 "${SCRIPT}" --sample S --kit rna002 --output /tmp/x
assert_exit_code "missing --kit exits 1" 1 "${SCRIPT}" --sample S --input /tmp --output /tmp/x
assert_exit_code "missing --sample exits 1" 1 "${SCRIPT}" --input /tmp --kit rna002 --output /tmp/x
assert_exit_code "missing --output exits 1" 1 "${SCRIPT}" --sample S --input /tmp --kit rna002
assert_exit_code "invalid --kit exits 1" 1 "${SCRIPT}" --sample S --input /tmp --kit banana --output /tmp/x
assert_exit_code "invalid --model-tier exits 1" 1 "${SCRIPT}" --sample S --input /tmp --kit rna002 --output /tmp/x --model-tier garbage
assert_exit_code "path-traversal --sample rejected" 1 "${SCRIPT}" --sample "../evil" --input /tmp --kit rna002 --output /tmp/x
assert_exit_code "slash in --sample rejected" 1 "${SCRIPT}" --sample "a/b" --input /tmp --kit rna002 --output /tmp/x

echo ""
echo "=== Input validation ==="
assert_exit_code "nonexistent input dir exits 4" 4 "${SCRIPT}" --sample S --input /no/such/dir/xyz --kit rna002 --output /tmp/x

# Create an empty temp dir and verify that counts as input error (4)
TMP_IN=$(mktemp -d)
TMP_OUT=$(mktemp -d)
trap 'rm -rf "${TMP_IN}" "${TMP_OUT}"' EXIT
assert_exit_code "empty input dir exits 4" 4 "${SCRIPT}" --sample S --input "${TMP_IN}" --kit rna002 --output "${TMP_OUT}"

# Touch both fast5 and pod5 files to simulate mixed input
touch "${TMP_IN}/a.fast5" "${TMP_IN}/b.pod5"
assert_exit_code "mixed formats exits 4" 4 "${SCRIPT}" --sample S --input "${TMP_IN}" --kit rna002 --output "${TMP_OUT}"
rm -f "${TMP_IN}"/*.fast5 "${TMP_IN}"/*.pod5

echo ""
echo "=== Summary ==="
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"
if [[ ${FAILED} -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${FAIL_LOG[@]}"; do echo "  - ${f}"; done
  exit 1
fi
exit 0
