# basecall.sh — Basecalling helpers for the prep-drs-data pipeline.
# Sourced by prep_drs.sh. Requires lib/utils.sh to be sourced first.

[[ "${_BASECALL_SH_LOADED:-}" == "1" ]] && return 0
_BASECALL_SH_LOADED=1

# ---------------------------------------------------------------------------
# run_guppy_basecall input_dir output_dir kit model_tier device
#
#   kit        : rna001 | rna002
#   model_tier : fast | hac | sup
#   device     : cuda:0 | cpu | etc.
#
# Override config entirely with GUPPY_CONFIG env var.
# ---------------------------------------------------------------------------
run_guppy_basecall() {
    local input_dir="${1:?run_guppy_basecall: input_dir required}"
    local output_dir="${2:?run_guppy_basecall: output_dir required}"
    local kit="${3:?run_guppy_basecall: kit required}"
    local model_tier="${4:?run_guppy_basecall: model_tier required}"
    local device="${5:?run_guppy_basecall: device required}"

    local config
    if [[ -n "${GUPPY_CONFIG:-}" ]]; then
        config="${GUPPY_CONFIG}"
    elif [[ "${kit}" == "rna001" ]]; then
        config="rna_r9.4.1_70bps_${model_tier}.cfg"
    elif [[ "${kit}" == "rna002" ]]; then
        config="rna_r9.4.1_70bps_${model_tier}_prom.cfg"
    else
        log_error "[basecall] run_guppy_basecall: unsupported kit '${kit}' (expected rna001 or rna002)"
        return 1
    fi

    log_info "[basecall] start: run_guppy_basecall input_dir=${input_dir} output_dir=${output_dir} kit=${kit} model_tier=${model_tier} device=${device} config=${config}"

    local cmd=(
        guppy_basecaller
        --input_path  "${input_dir}"
        --save_path   "${output_dir}"
        --config      "${config}"
        --device      "${device}"
        --compress_fastq
        --u_substitution on
        --trim_strategy rna
        --min_qscore 7
        --recursive
    )

    log_info "[basecall] running: ${cmd[*]}"
    "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# run_dorado_basecall input_dir output_fastq_gz model_tier threads
#
#   model_tier : fast | hac | sup
#   threads    : number of pigz compression threads
#
# Set DORADO_MODELS_DIR to use a local model directory (avoids download).
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

    log_info "[basecall] start: run_dorado_basecall input_dir=${input_dir} output_fastq_gz=${output_fastq_gz} model_tier=${model_tier} threads=${threads} model_ref=${model_ref}"

    # Capture and restore pipefail so the caller's setting is preserved.
    local _prev_pipefail
    _prev_pipefail="$(shopt -po pipefail)"
    set -o pipefail

    dorado basecaller "${model_ref}" "${input_dir}" --emit-fastq --min-qscore 7 \
        | pigz -p "${threads}" > "${output_fastq_gz}"
    local _dorado_status="${PIPESTATUS[0]}"
    local _pigz_status="${PIPESTATUS[1]}"

    # Restore previous pipefail state.
    eval "${_prev_pipefail}"

    if (( _dorado_status != 0 )); then
        log_error "[basecall] dorado basecaller failed (exit ${_dorado_status})"
        return "${_dorado_status}"
    fi

    if (( _pigz_status != 0 )); then
        log_error "[basecall] pigz compression failed (exit ${_pigz_status})"
        return "${_pigz_status}"
    fi

    if [[ ! -s "${output_fastq_gz}" ]]; then
        log_error "[basecall] output file is empty or missing: ${output_fastq_gz}"
        return 1
    fi

    log_info "[basecall] dorado basecall complete: ${output_fastq_gz}"
}

# ---------------------------------------------------------------------------
# convert_pod5_to_fast5 pod5_dir output_fast5_dir
# ---------------------------------------------------------------------------
convert_pod5_to_fast5() {
    local pod5_dir="${1:?convert_pod5_to_fast5: pod5_dir required}"
    local output_fast5_dir="${2:?convert_pod5_to_fast5: output_fast5_dir required}"

    log_info "[basecall] start: convert_pod5_to_fast5 pod5_dir=${pod5_dir} output_fast5_dir=${output_fast5_dir}"

    mkdir -p "${output_fast5_dir}"

    # Process each .pod5 file individually; safe across all pod5 CLI versions.
    find "${pod5_dir}" -type f -name '*.pod5' -print0 \
        | xargs -0 -I{} pod5 convert to_fast5 "{}" --output "${output_fast5_dir}/"
}

# ---------------------------------------------------------------------------
# convert_fast5_to_pod5 fast5_dir output_pod5_dir
#
# NOTE: Assumes a flat directory layout matching guppy output convention.
# For nested sub-directories, replace the glob with a find -exec pattern.
# ---------------------------------------------------------------------------
convert_fast5_to_pod5() {
    local fast5_dir="${1:?convert_fast5_to_pod5: fast5_dir required}"
    local output_pod5_dir="${2:?convert_fast5_to_pod5: output_pod5_dir required}"

    log_info "[basecall] start: convert_fast5_to_pod5 fast5_dir=${fast5_dir} output_pod5_dir=${output_pod5_dir}"

    mkdir -p "${output_pod5_dir}"

    pod5 convert fast5 "${fast5_dir}"/*.fast5 \
        --output "${output_pod5_dir}/" \
        --one-to-one "${fast5_dir}/"
}

# ---------------------------------------------------------------------------
# merge_guppy_fastq basecalled_dir output_fq_gz
# ---------------------------------------------------------------------------
merge_guppy_fastq() {
    local basecalled_dir="${1:?merge_guppy_fastq: basecalled_dir required}"
    local output_fq_gz="${2:?merge_guppy_fastq: output_fq_gz required}"

    log_info "[basecall] start: merge_guppy_fastq basecalled_dir=${basecalled_dir} output_fq_gz=${output_fq_gz}"

    local pass_dir="${basecalled_dir}/pass"
    if [[ ! -d "${pass_dir}" ]]; then
        log_error "[basecall] no pass/ directory found in ${basecalled_dir}"
        return 1
    fi

    # Detect compressed vs uncompressed pass reads.
    local gz_files=( "${pass_dir}"/*.fastq.gz )
    local fq_files=( "${pass_dir}"/*.fastq )

    local have_gz=0 have_fq=0
    [[ -e "${gz_files[0]}" ]] && have_gz=1
    [[ -e "${fq_files[0]}" ]]  && have_fq=1

    if (( have_gz == 0 && have_fq == 0 )); then
        log_error "[basecall] no .fastq.gz or .fastq files found in ${pass_dir}"
        return 1
    fi

    if (( have_gz )); then
        local count="${#gz_files[@]}"
        log_info "[basecall] merging ${count} compressed fastq.gz files"
        cat "${gz_files[@]}" > "${output_fq_gz}" || { log_error "[basecall] fastq merge (gz) failed"; return 1; }
    else
        local count="${#fq_files[@]}"
        log_info "[basecall] merging ${count} uncompressed fastq files (compressing with pigz)"
        cat "${fq_files[@]}" | pigz > "${output_fq_gz}" || { log_error "[basecall] fastq merge (pigz) failed"; return 1; }
    fi

    # Copy sequencing summary alongside the merged fastq if present.
    local summary_src="${basecalled_dir}/sequencing_summary.txt"
    if [[ -f "${summary_src}" ]]; then
        local output_dir
        output_dir="$(dirname "${output_fq_gz}")"
        cp "${summary_src}" "${output_dir}/sequencing_summary.txt"
        log_info "[basecall] copied sequencing_summary.txt to ${output_dir}/"
    fi

    log_info "[basecall] merge complete: ${output_fq_gz}"
}
