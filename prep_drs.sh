#!/usr/bin/env bash
# prep_drs.sh — Nanopore DRS data preparation pipeline.
# Converts fast5/pod5 raw data into {fastq/pass.fq.gz, blow5/nanopore.drs.blow5, pod5|fast5/}
# Basecallers: dorado-legacy (v0.9.6) for rna001/002, dorado (current) for rna004.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve lib dir: dev mode (./lib) first, then Docker install path
if [[ -d "${SCRIPT_DIR}/lib" ]]; then
  LIB_DIR="${SCRIPT_DIR}/lib"
elif [[ -d "/usr/local/lib/prep-drs" ]]; then
  LIB_DIR="/usr/local/lib/prep-drs"
else
  echo "ERROR: cannot locate lib/ directory" >&2
  exit 1
fi

# shellcheck source=lib/utils.sh
source "${LIB_DIR}/utils.sh"
# shellcheck source=lib/basecall.sh
source "${LIB_DIR}/basecall.sh"
# shellcheck source=lib/signal_convert.sh
source "${LIB_DIR}/signal_convert.sh"

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

cleanup() {
  local exit_code=$?
  if [[ ${KEEP_TMP:-0} -eq 0 && -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
    log_info "[cleanup] removing ${TMP_DIR}"
    rm -rf "${TMP_DIR}" || true
  fi
  exit ${exit_code}
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Stage functions
# ---------------------------------------------------------------------------

stage_validate_deps() {
  local tools=(slow5tools pigz find)

  case "${KIT}" in
    rna001|rna002)
      tools+=(dorado-legacy)
      ;;
    rna004)
      tools+=(dorado)
      ;;
  esac

  # pod5 input → needs blue-crab for signal conversion
  if [[ "${INPUT_FORMAT}" == "pod5" ]]; then
    tools+=(blue-crab)
  fi

  # fast5 input + rna004 → needs pod5 CLI for fast5→pod5 conversion
  # (dorado-legacy accepts fast5 natively, so rna001/002 need no pod5 CLI)
  if [[ "${INPUT_FORMAT}" == "fast5" && "${KIT}" == "rna004" ]]; then
    tools+=(pod5)
  fi

  check_deps "${tools[@]}"
  check_gpu
}

stage_prepare_dirs() {
  SAMPLE_DIR="${OUTPUT}/${SAMPLE}"
  TMP_DIR="${SAMPLE_DIR}/.tmp"
  FASTQ_DIR="${SAMPLE_DIR}/fastq"
  BLOW5_DIR="${SAMPLE_DIR}/blow5"
  RAW_DIR_NAME="${INPUT_FORMAT}"  # fast5 or pod5
  RAW_DIR="${SAMPLE_DIR}/${RAW_DIR_NAME}"

  local final_fq="${FASTQ_DIR}/pass.fq.gz"
  local final_b5="${BLOW5_DIR}/nanopore.drs.blow5"
  if [[ ${FORCE} -eq 0 && -s "${final_fq}" && -s "${final_b5}" ]]; then
    log_info "Outputs already exist at ${SAMPLE_DIR}; use --force to re-run. Exiting 0."
    # Disable cleanup trap since we aren't exiting abnormally
    trap - EXIT
    exit 0
  fi

  mkdir -p "${FASTQ_DIR}" "${BLOW5_DIR}" "${TMP_DIR}" "${RAW_DIR}"
}

stage_basecalling() {
  local basecall_input

  case "${KIT}" in
    rna001|rna002)
      # dorado-legacy (0.9.6) accepts both fast5 and pod5 natively.
      basecall_input="${INPUT}"

      run_dorado_legacy_basecall \
        "${basecall_input}" \
        "${FASTQ_DIR}/pass.fq.gz" \
        "${KIT}" \
        "${MODEL_TIER}" \
        "${THREADS}" \
        || die 5 "dorado-legacy basecalling failed"
      ;;

    rna004)
      # Current dorado only accepts pod5 — convert fast5 first if needed.
      if [[ "${INPUT_FORMAT}" == "fast5" ]]; then
        log_info "[basecall] fast5 input with dorado — converting fast5 -> pod5 first"
        convert_fast5_to_pod5 "${INPUT}" "${TMP_DIR}/pod5_converted" \
          || die 5 "fast5->pod5 conversion failed"
        basecall_input="${TMP_DIR}/pod5_converted"
      else
        basecall_input="${INPUT}"
      fi

      run_dorado_basecall \
        "${basecall_input}" \
        "${FASTQ_DIR}/pass.fq.gz" \
        "${MODEL_TIER}" \
        "${THREADS}" \
        || die 5 "dorado basecalling failed"
      ;;
  esac
}

stage_fastq_integrity() {
  check_fastq_integrity "${FASTQ_DIR}/pass.fq.gz" \
    || die 7 "fastq integrity check failed"

  local n
  n="$(count_fastq_reads "${FASTQ_DIR}/pass.fq.gz" 2>/dev/null || echo "?")"
  log_info "fastq reads: ${n}"
}

stage_signal_convert() {
  local parts_dir="${TMP_DIR}/blow5_parts"
  mkdir -p "${parts_dir}"

  if [[ "${INPUT_FORMAT}" == "fast5" ]]; then
    convert_fast5_to_blow5 "${INPUT}" "${parts_dir}" "${THREADS}" "${ZSTD}" \
      || die 6 "fast5->blow5 failed"
  else
    convert_pod5_to_blow5 "${INPUT}" "${parts_dir}" "${ZSTD}" \
      || die 6 "pod5->blow5 failed"
  fi
}

stage_blow5_merge() {
  merge_blow5 "${TMP_DIR}/blow5_parts" "${BLOW5_DIR}/nanopore.drs.blow5" "${THREADS}" \
    || die 6 "blow5 merge failed"
}

stage_blow5_integrity() {
  check_blow5_integrity "${BLOW5_DIR}/nanopore.drs.blow5" \
    || die 7 "blow5 quickcheck failed"
}

stage_move_raw() {
  log_info "[raw] ${COPY_MODE:+copying}${COPY_MODE:-moving} raw files to ${RAW_DIR}"
  # Use find to handle nested layouts
  while IFS= read -r -d '' f; do
    if [[ ${COPY_MODE} -eq 1 ]]; then
      cp "${f}" "${RAW_DIR}/" || die 8 "copy failed: ${f}"
    else
      mv "${f}" "${RAW_DIR}/" || die 8 "move failed: ${f}"
    fi
  done < <(find "${INPUT}" -type f \( -name '*.fast5' -o -name '*.pod5' \) -print0)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local start_time=$SECONDS
  parse_args "$@"
  log_info "prep_drs.sh starting — sample=${SAMPLE} kit=${KIT} input=${INPUT} output=${OUTPUT}"

  detect_input_format "${INPUT}"
  log_info "Input format: ${INPUT_FORMAT} (${INPUT_FILE_COUNT} files)"

  stage_validate_deps
  stage_prepare_dirs
  stage_basecalling
  stage_fastq_integrity
  stage_signal_convert
  stage_blow5_merge
  stage_blow5_integrity
  stage_move_raw

  local elapsed=$(( SECONDS - start_time ))
  log_info "Pipeline complete in ${elapsed}s"
  log_info "Outputs:"
  find "${SAMPLE_DIR}" -maxdepth 2 -type f -printf '  %p  (%s bytes)\n' | grep -v '\.tmp' || true

  # Explicit success exit so trap's $? is 0
  trap - EXIT
  if [[ ${KEEP_TMP} -eq 0 && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
  exit 0
}

main "$@"
