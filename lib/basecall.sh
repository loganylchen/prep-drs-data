# basecall.sh — Basecalling helpers for the prep-drs-data pipeline.
# Sourced by prep_drs.sh. Requires lib/utils.sh to be sourced first.
#
# Basecaller selection:
#   rna001 / rna002 → dorado-legacy (v0.9.6 — last version supporting RNA002)
#                     accepts BOTH fast5 and pod5 natively
#   rna004          → dorado (current, e.g. v1.4.0)
#                     accepts pod5 only; fast5 must be converted first

[[ "${_BASECALL_SH_LOADED:-}" == "1" ]] && return 0
_BASECALL_SH_LOADED=1

# ---------------------------------------------------------------------------
# _run_dorado_pipeline binary input_dir output_fastq_gz model_ref threads
#
# Internal helper: runs `<binary> basecaller <model> <input> --emit-fastq` and
# pipes through pigz to the output file. Handles pipefail save/restore and
# PIPESTATUS checks.
# ---------------------------------------------------------------------------
_run_dorado_pipeline() {
    local binary="${1:?_run_dorado_pipeline: binary required}"
    local input_dir="${2:?_run_dorado_pipeline: input_dir required}"
    local output_fastq_gz="${3:?_run_dorado_pipeline: output_fastq_gz required}"
    local model_ref="${4:?_run_dorado_pipeline: model_ref required}"
    local threads="${5:?_run_dorado_pipeline: threads required}"

    log_info "[basecall] running: ${binary} basecaller ${model_ref} ${input_dir} --emit-fastq --min-qscore 7 | pigz -p ${threads} > ${output_fastq_gz}"

    local _prev_pipefail
    _prev_pipefail="$(shopt -po pipefail)"
    set -o pipefail

    "${binary}" basecaller "${model_ref}" "${input_dir}" --emit-fastq --min-qscore 7 \
        | pigz -p "${threads}" > "${output_fastq_gz}"
    local _bc_status="${PIPESTATUS[0]}"
    local _pigz_status="${PIPESTATUS[1]}"

    eval "${_prev_pipefail}"

    if (( _bc_status != 0 )); then
        log_error "[basecall] ${binary} basecaller failed (exit ${_bc_status})"
        return "${_bc_status}"
    fi
    if (( _pigz_status != 0 )); then
        log_error "[basecall] pigz compression failed (exit ${_pigz_status})"
        return "${_pigz_status}"
    fi
    if [[ ! -s "${output_fastq_gz}" ]]; then
        log_error "[basecall] output file is empty or missing: ${output_fastq_gz}"
        return 1
    fi

    log_info "[basecall] basecall complete: ${output_fastq_gz}"
}

# ---------------------------------------------------------------------------
# run_dorado_legacy_basecall input_dir output_fastq_gz kit model_tier threads
#
#   kit        : rna001 | rna002  (both use the same rna002_70bps_hac@v3 model)
#   model_tier : fast | hac | sup  (only hac exists for RNA002; others trigger warning)
#   threads    : pigz compression threads
#
# Uses /usr/local/bin/dorado-legacy (v0.9.6). Accepts fast5 OR pod5 input.
# ---------------------------------------------------------------------------
run_dorado_legacy_basecall() {
    local input_dir="${1:?run_dorado_legacy_basecall: input_dir required}"
    local output_fastq_gz="${2:?run_dorado_legacy_basecall: output_fastq_gz required}"
    local kit="${3:?run_dorado_legacy_basecall: kit required}"
    local model_tier="${4:?run_dorado_legacy_basecall: model_tier required}"
    local threads="${5:?run_dorado_legacy_basecall: threads required}"

    if [[ "${kit}" != "rna001" && "${kit}" != "rna002" ]]; then
        log_error "[basecall] run_dorado_legacy_basecall: unsupported kit '${kit}' (expected rna001 or rna002)"
        return 1
    fi

    # dorado only ships one RNA002 model: rna002_70bps_hac@v3.
    # There is no fast/sup variant. Warn if the user requested one.
    if [[ "${model_tier}" != "hac" ]]; then
        log_warn "[basecall] RNA002 only has a 'hac' model; ignoring --model-tier=${model_tier}"
    fi

    local model_name="rna002_70bps_hac@v3"
    local model_ref="${model_name}"

    if [[ -n "${DORADO_MODELS_DIR:-}" && -d "${DORADO_MODELS_DIR}/${model_name}" ]]; then
        model_ref="${DORADO_MODELS_DIR}/${model_name}"
        log_info "[basecall] using local model directory: ${model_ref}"
    fi

    log_info "[basecall] start: run_dorado_legacy_basecall input_dir=${input_dir} output_fastq_gz=${output_fastq_gz} kit=${kit} model_ref=${model_ref} threads=${threads}"

    _run_dorado_pipeline "dorado-legacy" "${input_dir}" "${output_fastq_gz}" "${model_ref}" "${threads}"
}

# ---------------------------------------------------------------------------
# run_dorado_basecall input_dir output_fastq_gz model_tier threads
#
#   model_tier : fast | hac | sup
#   threads    : pigz compression threads
#
# Uses /usr/local/bin/dorado (current, e.g. v1.4.0). Requires pod5 input.
# ---------------------------------------------------------------------------
run_dorado_basecall() {
    local input_dir="${1:?run_dorado_basecall: input_dir required}"
    local output_fastq_gz="${2:?run_dorado_basecall: output_fastq_gz required}"
    local model_tier="${3:?run_dorado_basecall: model_tier required}"
    local threads="${4:?run_dorado_basecall: threads required}"

    local model_name="rna004_130bps_${model_tier}@v5.2.0"
    local model_ref="${model_name}"

    if [[ -n "${DORADO_MODELS_DIR:-}" && -d "${DORADO_MODELS_DIR}/${model_name}" ]]; then
        model_ref="${DORADO_MODELS_DIR}/${model_name}"
        log_info "[basecall] using local model directory: ${model_ref}"
    fi

    log_info "[basecall] start: run_dorado_basecall input_dir=${input_dir} output_fastq_gz=${output_fastq_gz} model_tier=${model_tier} model_ref=${model_ref} threads=${threads}"

    _run_dorado_pipeline "dorado" "${input_dir}" "${output_fastq_gz}" "${model_ref}" "${threads}"
}

# ---------------------------------------------------------------------------
# convert_fast5_to_pod5 fast5_dir output_pod5_dir
#
# Used for the RNA004 + fast5 input case. Current dorado (>=1.0) only accepts
# pod5, so fast5 must be converted first.
# NOTE: Assumes a flat directory layout. Nested sub-directories require find.
# ---------------------------------------------------------------------------
convert_fast5_to_pod5() {
    local fast5_dir="${1:?convert_fast5_to_pod5: fast5_dir required}"
    local output_pod5_dir="${2:?convert_fast5_to_pod5: output_pod5_dir required}"

    log_info "[basecall] start: convert_fast5_to_pod5 fast5_dir=${fast5_dir} output_pod5_dir=${output_pod5_dir}"

    mkdir -p "${output_pod5_dir}"

    local files=( "${fast5_dir}"/*.fast5 )
    if [[ ! -e "${files[0]}" ]]; then
        log_error "[basecall] no .fast5 files found in ${fast5_dir}"
        return 1
    fi

    pod5 convert fast5 "${files[@]}" \
        --output "${output_pod5_dir}/" \
        --one-to-one "${fast5_dir}/"
}
