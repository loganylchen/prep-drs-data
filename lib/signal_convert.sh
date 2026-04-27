#!/usr/bin/env bash
# signal_convert.sh — signal file conversion and integrity helpers for prep_drs.sh
# Sourced by prep_drs.sh after lib/utils.sh has been sourced.

[[ "${_SIGNAL_CONVERT_SH_LOADED:-}" == "1" ]] && return 0
_SIGNAL_CONVERT_SH_LOADED=1

# convert_fast5_to_blow5 <fast5_dir> <blow5_parts_dir> <threads> <use_zstd>
convert_fast5_to_blow5() {
    local fast5_dir="${1}"
    local blow5_parts_dir="${2}"
    local threads="${3}"
    local use_zstd="${4}"

    local compression=()
    if [[ "${use_zstd}" == "1" ]]; then
        compression=(-c zstd -s svb-zd)
    fi

    log_info "[signal] Converting FAST5 -> BLOW5: ${fast5_dir} -> ${blow5_parts_dir} (threads=${threads}, zstd=${use_zstd})"

    mkdir -p "${blow5_parts_dir}" || {
        log_error "[signal] Failed to create directory: ${blow5_parts_dir}"
        return 1
    }

    # --allow tells slow5tools to skip auxiliary-attribute quirks instead of
    # aborting the whole conversion. Required for fast5 produced by guppy
    # (and some other ONT tools) that have run-id conflicts or missing
    # aux attrs like Raw/start_time. Signal data is unaffected.
    log_info "[signal] Running: slow5tools f2s \"${fast5_dir}\" -d \"${blow5_parts_dir}\" -p \"${threads}\" --allow ${compression[*]}"
    slow5tools f2s "${fast5_dir}" -d "${blow5_parts_dir}" -p "${threads}" --allow "${compression[@]}" || {
        log_error "[signal] slow5tools f2s failed"
        return 1
    }
}

# convert_pod5_to_blow5 <pod5_dir> <blow5_parts_dir> <use_zstd>
convert_pod5_to_blow5() {
    local pod5_dir="${1}"
    local blow5_parts_dir="${2}"
    local use_zstd="${3}"

    local compression=()
    if [[ "${use_zstd}" == "1" ]]; then
        compression=(-c zstd)
    fi

    log_info "[signal] Converting POD5 -> BLOW5: ${pod5_dir} -> ${blow5_parts_dir} (zstd=${use_zstd})"

    mkdir -p "${blow5_parts_dir}" || {
        log_error "[signal] Failed to create directory: ${blow5_parts_dir}"
        return 1
    }

    log_info "[signal] Running: blue-crab p2s \"${pod5_dir}\" -d \"${blow5_parts_dir}\" ${compression[*]}"
    blue-crab p2s "${pod5_dir}" -d "${blow5_parts_dir}" "${compression[@]}" || {
        log_error "[signal] blue-crab p2s failed"
        return 1
    }
}

# merge_blow5 <blow5_parts_dir> <output_blow5> <threads>
merge_blow5() {
    local blow5_parts_dir="${1}"
    local output_blow5="${2}"
    local threads="${3}"

    log_info "[signal] Merging BLOW5 parts in ${blow5_parts_dir} -> ${output_blow5} (threads=${threads})"

    local parts
    parts=("${blow5_parts_dir}"/*.blow5)
    if [[ ! -e "${parts[0]}" ]]; then
        log_error "[signal] No .blow5 files found in ${blow5_parts_dir}"
        return 1
    fi

    log_info "[signal] Running: slow5tools merge \"${blow5_parts_dir}\" -o \"${output_blow5}\" -t \"${threads}\""
    slow5tools merge "${blow5_parts_dir}" -o "${output_blow5}" -t "${threads}" || {
        log_error "[signal] slow5tools merge failed"
        return 1
    }
}

# check_blow5_integrity <blow5_file>
check_blow5_integrity() {
    local blow5_file="${1}"

    log_info "[signal] Checking BLOW5 integrity: ${blow5_file}"

    if [[ ! -s "${blow5_file}" ]]; then
        log_error "[signal] BLOW5 file missing or empty: ${blow5_file}"
        return 1
    fi

    slow5tools quickcheck "${blow5_file}" || {
        log_error "[signal] slow5tools quickcheck failed for ${blow5_file}"
        return 1
    }
}

# check_fastq_integrity <fastq_gz_file>
check_fastq_integrity() {
    local fastq_gz_file="${1}"

    log_info "[signal] Checking FASTQ integrity: ${fastq_gz_file}"

    if [[ ! -s "${fastq_gz_file}" ]]; then
        log_error "[signal] FASTQ file missing or empty: ${fastq_gz_file}"
        return 1
    fi

    gzip -t "${fastq_gz_file}" || {
        log_error "[signal] gzip integrity check failed for ${fastq_gz_file}"
        return 1
    }
}

# count_fastq_reads <fastq_gz_file>
# Prints approximate read count to stdout.
count_fastq_reads() {
    local fastq_gz_file="${1}"

    log_info "[signal] Counting reads in ${fastq_gz_file}"

    echo $(($(zcat "${fastq_gz_file}" | wc -l) / 4))
}
