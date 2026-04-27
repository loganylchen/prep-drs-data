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
# shellcheck source=lib/qc.sh
source "${LIB_DIR}/qc.sh"

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

  if [[ ${SKIP_QC} -eq 0 ]]; then
    tools+=(NanoPlot)
  fi

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
  # (dorado-legacy accepts fast5 natively, so rna001/002 only need pod5 CLI
  #  when the user opts in via --prefer-pod5)
  if [[ "${INPUT_FORMAT}" == "fast5" && "${KIT}" == "rna004" ]]; then
    tools+=(pod5)
  elif [[ "${INPUT_FORMAT}" == "fast5" && "${PREFER_POD5}" -eq 1 ]]; then
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
  QC_DIR="${SAMPLE_DIR}/qc"
  RAW_DIR_NAME="${INPUT_FORMAT}"  # fast5 or pod5
  RAW_DIR="${SAMPLE_DIR}/${RAW_DIR_NAME}"

  local final_fq="${FASTQ_DIR}/pass.fq.gz"
  local final_b5="${BLOW5_DIR}/nanopore.drs.blow5"
  local final_qc="${QC_DIR}/qc_report.md"
  local qc_ok=1
  if [[ ${SKIP_QC} -eq 0 && ! -s "${final_qc}" ]]; then
    qc_ok=0
  fi
  if [[ ${FORCE} -eq 0 && -s "${final_fq}" && -s "${final_b5}" && ${qc_ok} -eq 1 ]]; then
    log_info "Outputs already exist at ${SAMPLE_DIR}; use --force to re-run. Exiting 0."
    # Disable cleanup trap since we aren't exiting abnormally
    trap - EXIT
    exit 0
  fi

  mkdir -p "${FASTQ_DIR}" "${BLOW5_DIR}" "${TMP_DIR}" "${RAW_DIR}"
  if [[ ${SKIP_QC} -eq 0 ]]; then
    mkdir -p "${QC_DIR}"
  fi
}

stage_basecalling() {
  local basecall_input
  local final_fq="${FASTQ_DIR}/pass.fq.gz"

  # Per-stage resume: if fastq already exists and is non-empty, skip.
  # Lets users recover from a downstream crash (e.g. signal-convert, QC)
  # without redoing the multi-hour basecalling step.
  if [[ ${FORCE} -eq 0 && -s "${final_fq}" ]]; then
    log_info "[basecall] ${final_fq} already exists; skipping basecalling (use --force to re-run)"
    return 0
  fi

  case "${KIT}" in
    rna001|rna002)
      # dorado-legacy (0.9.6) accepts both fast5 and pod5 natively.
      # pod5 is typically 15-30% faster on the data-loading path, so if the
      # user opts in via --prefer-pod5 and the input is fast5, convert first.
      if [[ "${INPUT_FORMAT}" == "fast5" && "${PREFER_POD5}" -eq 1 ]]; then
        log_info "[basecall] --prefer-pod5 set: converting fast5 -> pod5 before dorado-legacy"
        convert_fast5_to_pod5 "${INPUT}" "${TMP_DIR}/pod5_converted" \
          || die 5 "fast5->pod5 conversion failed"
        basecall_input="${TMP_DIR}/pod5_converted"
      else
        basecall_input="${INPUT}"
      fi

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
  local final_b5="${BLOW5_DIR}/nanopore.drs.blow5"

  # Per-stage resume: if merged blow5 already exists, skip conversion.
  if [[ ${FORCE} -eq 0 && -s "${final_b5}" ]]; then
    log_info "[signal] ${final_b5} already exists; skipping fast5/pod5->blow5 (use --force to re-run)"
    return 0
  fi

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
  local final_b5="${BLOW5_DIR}/nanopore.drs.blow5"

  if [[ ${FORCE} -eq 0 && -s "${final_b5}" ]]; then
    log_info "[signal] ${final_b5} already exists; skipping merge"
    return 0
  fi

  merge_blow5 "${TMP_DIR}/blow5_parts" "${final_b5}" "${THREADS}" \
    || die 6 "blow5 merge failed"
}

stage_blow5_integrity() {
  check_blow5_integrity "${BLOW5_DIR}/nanopore.drs.blow5" \
    || die 7 "blow5 quickcheck failed"
}

stage_qc() {
  if [[ ${SKIP_QC} -eq 1 ]]; then
    log_info "[qc] --skip-qc set; skipping QC report generation"
    return 0
  fi

  local fastq_gz="${FASTQ_DIR}/pass.fq.gz"
  local blow5_file="${BLOW5_DIR}/nanopore.drs.blow5"
  local nanoplot_dir="${QC_DIR}/nanoplot"
  local blow5_stats_file="${QC_DIR}/blow5_stats.txt"

  run_nanoplot "${fastq_gz}" "${nanoplot_dir}" "${THREADS}" "${SAMPLE}" \
    || die 9 "NanoPlot QC failed"

  run_blow5_stats "${blow5_file}" "${blow5_stats_file}" \
    || die 9 "slow5tools stats failed"

  generate_qc_report \
    "${SAMPLE}" "${KIT}" "${MODEL_TIER}" \
    "${fastq_gz}" "${blow5_file}" "${QC_DIR}" \
    || die 9 "QC report generation failed"
}

stage_move_raw() {
  # Enumerate first so we can compute the common ancestor of the actual files,
  # then preserve only the structure below that ancestor. Flat input -> flat
  # output; batched input (e.g. MinKNOW /in/0, /in/1, ...) -> output keeps
  # the batch dirs but drops any dead path components above them.
  local files=()
  while IFS= read -r -d '' f; do
    files+=("${f}")
  done < <(find "${INPUT}" -type f \( -name '*.fast5' -o -name '*.pod5' \) -print0)

  if [[ ${#files[@]} -eq 0 ]]; then
    log_warn "[raw] no fast5/pod5 files found under ${INPUT}; nothing to ${COPY_MODE:+copy}${COPY_MODE:-move}"
    return 0
  fi

  local ancestor
  ancestor="$(compute_common_ancestor "${files[@]}")"
  log_info "[raw] ${COPY_MODE:+copying}${COPY_MODE:-moving} ${#files[@]} raw file(s) to ${RAW_DIR} (preserving paths relative to ${ancestor})"

  local f rel dest dest_dir strip
  if [[ "${ancestor}" == "/" ]]; then
    strip="/"
  else
    strip="${ancestor}/"
  fi
  for f in "${files[@]}"; do
    rel="${f#${strip}}"
    dest="${RAW_DIR}/${rel}"
    dest_dir="$(dirname "${dest}")"
    mkdir -p "${dest_dir}" || die 8 "mkdir failed: ${dest_dir}"
    if [[ ${COPY_MODE} -eq 1 ]]; then
      cp "${f}" "${dest}" || die 8 "copy failed: ${f}"
    else
      mv "${f}" "${dest}" || die 8 "move failed: ${f}"
    fi
  done
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
  stage_qc
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
