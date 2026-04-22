# qc.sh — QC report generation for the prep-drs-data pipeline.
# Sourced by prep_drs.sh. Requires lib/utils.sh to be sourced first.
#
# Produces, under <sample>/qc/ :
#   nanoplot/                # NanoPlot HTML report + stats + plots
#   fastq_summary.txt        # read count / total bases / N50 (pulled from NanoStats)
#   blow5_stats.txt          # slow5tools stats output
#   qc_report.md             # consolidated Markdown summary

[[ "${_QC_SH_LOADED:-}" == "1" ]] && return 0
_QC_SH_LOADED=1

# ---------------------------------------------------------------------------
# run_nanoplot fastq_gz outdir threads sample_title
# ---------------------------------------------------------------------------
run_nanoplot() {
    local fastq_gz="${1:?run_nanoplot: fastq_gz required}"
    local outdir="${2:?run_nanoplot: outdir required}"
    local threads="${3:?run_nanoplot: threads required}"
    local title="${4:-sample}"

    log_info "[qc] running NanoPlot on ${fastq_gz}"
    mkdir -p "${outdir}"

    # NanoPlot is happy with .fq.gz directly.
    # --tsv_stats produces NanoStats.txt which we parse later.
    if ! NanoPlot \
            --fastq "${fastq_gz}" \
            --outdir "${outdir}" \
            --threads "${threads}" \
            --title "${title}" \
            --tsv_stats \
            --no_static \
            > "${outdir}/nanoplot.log" 2>&1; then
        log_error "[qc] NanoPlot failed; see ${outdir}/nanoplot.log"
        return 1
    fi

    log_info "[qc] NanoPlot complete: ${outdir}/NanoPlot-report.html"
}

# ---------------------------------------------------------------------------
# run_blow5_stats blow5_file outfile
# ---------------------------------------------------------------------------
run_blow5_stats() {
    local blow5_file="${1:?run_blow5_stats: blow5_file required}"
    local outfile="${2:?run_blow5_stats: outfile required}"

    log_info "[qc] collecting slow5tools stats for ${blow5_file}"
    if ! slow5tools stats "${blow5_file}" > "${outfile}" 2>&1; then
        log_error "[qc] slow5tools stats failed; see ${outfile}"
        return 1
    fi
    log_info "[qc] blow5 stats written to ${outfile}"
}

# ---------------------------------------------------------------------------
# generate_qc_report sample kit model_tier fastq_gz blow5_file qc_dir
#
# Consolidates NanoPlot + slow5tools stats into a single Markdown report.
# ---------------------------------------------------------------------------
generate_qc_report() {
    local sample="${1:?generate_qc_report: sample required}"
    local kit="${2:?generate_qc_report: kit required}"
    local model_tier="${3:?generate_qc_report: model_tier required}"
    local fastq_gz="${4:?generate_qc_report: fastq_gz required}"
    local blow5_file="${5:?generate_qc_report: blow5_file required}"
    local qc_dir="${6:?generate_qc_report: qc_dir required}"

    local report="${qc_dir}/qc_report.md"
    local nanostats="${qc_dir}/nanoplot/NanoStats.txt"
    local blow5_stats="${qc_dir}/blow5_stats.txt"
    local nanoplot_html="${qc_dir}/nanoplot/NanoPlot-report.html"

    local now_utc
    now_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    {
        printf '# QC report — %s\n\n' "${sample}"
        printf '| field | value |\n|-------|-------|\n'
        printf '| sample | %s |\n' "${sample}"
        printf '| kit | %s |\n' "${kit}"
        printf '| model_tier | %s |\n' "${model_tier}"
        printf '| generated_at | %s |\n' "${now_utc}"
        printf '| fastq | %s |\n' "$(basename "${fastq_gz}")"
        printf '| blow5 | %s |\n' "$(basename "${blow5_file}")"
        printf '\n'

        printf '## FASTQ stats (from NanoPlot)\n\n'
        if [[ -s "${nanostats}" ]]; then
            printf '```\n'
            cat "${nanostats}"
            printf '```\n\n'
        else
            printf '_NanoStats.txt not found at %s_\n\n' "${nanostats}"
        fi

        printf '## BLOW5 stats (from slow5tools)\n\n'
        if [[ -s "${blow5_stats}" ]]; then
            printf '```\n'
            cat "${blow5_stats}"
            printf '```\n\n'
        else
            printf '_blow5_stats.txt not found at %s_\n\n' "${blow5_stats}"
        fi

        printf '## Artifacts\n\n'
        printf -- '- NanoPlot HTML report: `qc/nanoplot/NanoPlot-report.html`\n'
        printf -- '- NanoPlot stats: `qc/nanoplot/NanoStats.txt`\n'
        printf -- '- BLOW5 stats: `qc/blow5_stats.txt`\n'
    } > "${report}"

    # Extract a brief one-line summary for the pipeline log
    if [[ -s "${nanostats}" ]]; then
        local num_reads mean_qual median_len n50
        num_reads="$(awk -F'\t' '$1=="number_of_reads"{print $2; exit}' "${nanostats}" 2>/dev/null || echo '?')"
        mean_qual="$(awk -F'\t' '$1=="mean_qual"{print $2; exit}' "${nanostats}" 2>/dev/null || echo '?')"
        median_len="$(awk -F'\t' '$1=="median_read_length"{print $2; exit}' "${nanostats}" 2>/dev/null || echo '?')"
        n50="$(awk -F'\t' '$1=="n50"{print $2; exit}' "${nanostats}" 2>/dev/null || echo '?')"
        log_info "[qc] reads=${num_reads} median_len=${median_len} N50=${n50} mean_qual=${mean_qual}"
    fi

    log_info "[qc] report written: ${report}"
    if [[ -s "${nanoplot_html}" ]]; then
        log_info "[qc] NanoPlot HTML: ${nanoplot_html}"
    fi
}
