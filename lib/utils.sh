# utils.sh — shared utilities for prep_drs.sh (source this file, do not execute directly)
# Guard against double-sourcing
[[ "${_UTILS_SH_LOADED:-}" == "1" ]] && return 0
_UTILS_SH_LOADED=1

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info() {
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '[%s INFO] %s\n' "${ts}" "$*" >&2
}

log_warn() {
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '[%s WARN] %s\n' "${ts}" "$*" >&2
}

log_error() {
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '[%s ERROR] %s\n' "${ts}" "$*" >&2
}

die() {
    local exit_code="$1"
    shift
    log_error "$*"
    exit "${exit_code}"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps() {
    local missing=()
    local tool
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            missing+=("${tool}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# GPU check
# ---------------------------------------------------------------------------

check_gpu() {
    local gpu_info
    if ! gpu_info="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1)"; then
        log_error "nvidia-smi failed: ${gpu_info}"
        exit 3
    fi
    log_info "GPU detected: ${gpu_info}"
}

# ---------------------------------------------------------------------------
# Input format detection
# ---------------------------------------------------------------------------

detect_input_format() {
    local input_dir="$1"
    local fast5_count pod5_count

    fast5_count="$(find "${input_dir}" -type f -name '*.fast5' | wc -l)"
    pod5_count="$(find "${input_dir}" -type f -name '*.pod5' | wc -l)"

    if [[ "${fast5_count}" -gt 0 && "${pod5_count}" -gt 0 ]]; then
        log_error "Mixed input formats detected: ${fast5_count} fast5 and ${pod5_count} pod5 files in ${input_dir}"
        exit 4
    elif [[ "${fast5_count}" -eq 0 && "${pod5_count}" -eq 0 ]]; then
        log_error "No fast5 or pod5 files found in ${input_dir}"
        exit 4
    elif [[ "${fast5_count}" -gt 0 ]]; then
        INPUT_FORMAT="fast5"
        INPUT_FILE_COUNT="${fast5_count}"
    else
        INPUT_FORMAT="pod5"
        INPUT_FILE_COUNT="${pod5_count}"
    fi

    log_info "Input format: ${INPUT_FORMAT} (${INPUT_FILE_COUNT} files)"
}

# ---------------------------------------------------------------------------
# Usage printer
# ---------------------------------------------------------------------------

print_usage() {
    cat <<'EOF'
Usage: prep_drs.sh --sample NAME --input DIR --kit KIT --output DIR [OPTIONS]

Required:
  --sample NAME       Sample name (output subdirectory)
  --input DIR         Directory containing fast5 or pod5 files
  --kit KIT           One of: rna001, rna002, rna004
  --output DIR        Base output directory

Options:
  --threads N         CPU threads (default: nproc)
  --model-tier T      Basecalling model tier: fast, hac, sup (default: hac)
  --device D          GPU device (default: cuda:0)
  --copy              Copy raw files instead of moving them
  --zstd              Use zstd compression for BLOW5
  --force             Re-run even if outputs exist
  --keep-tmp          Preserve .tmp workspace after completion
  --skip-qc           Skip NanoPlot + slow5tools stats QC report
  --prefer-pod5       For RNA001/RNA002 + fast5 input, convert fast5->pod5
                      in .tmp/ before basecalling (typically 15-30% faster,
                      but needs extra disk ~= input size)
  --help              Print this help and exit

Exit codes: 0 success, 1 args, 2 missing deps, 3 no GPU,
            4 input error, 5 basecall fail, 6 signal conv fail,
            7 integrity fail, 8 move/copy fail, 9 QC fail
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    # Defaults
    SAMPLE=""
    INPUT=""
    KIT=""
    OUTPUT=""
    THREADS="$(nproc)"
    MODEL_TIER="hac"
    DEVICE="cuda:0"
    COPY_MODE=0
    ZSTD=0
    FORCE=0
    KEEP_TMP=0
    SKIP_QC=0
    PREFER_POD5=0

    while [[ $# -gt 0 ]]; do
        local key="$1"
        case "${key}" in
            --sample)
                SAMPLE="$2"
                shift 2
                ;;
            --input)
                INPUT="$2"
                shift 2
                ;;
            --kit)
                KIT="$2"
                shift 2
                ;;
            --output)
                OUTPUT="$2"
                shift 2
                ;;
            --threads)
                THREADS="$2"
                shift 2
                ;;
            --model-tier)
                MODEL_TIER="$2"
                shift 2
                ;;
            --device)
                DEVICE="$2"
                shift 2
                ;;
            --copy)
                COPY_MODE=1
                shift
                ;;
            --zstd)
                ZSTD=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --keep-tmp)
                KEEP_TMP=1
                shift
                ;;
            --skip-qc)
                SKIP_QC=1
                shift
                ;;
            --prefer-pod5)
                PREFER_POD5=1
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: ${key}"
                print_usage
                exit 1
                ;;
        esac
    done

    # Validate required args
    local missing_required=()
    [[ -z "${SAMPLE}" ]] && missing_required+=("--sample")
    [[ -z "${INPUT}" ]]  && missing_required+=("--input")
    [[ -z "${KIT}" ]]    && missing_required+=("--kit")
    [[ -z "${OUTPUT}" ]] && missing_required+=("--output")

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        log_error "Missing required arguments: ${missing_required[*]}"
        print_usage
        exit 1
    fi

    # Sanitize SAMPLE: must be a simple directory name, no path traversal
    if [[ "${SAMPLE}" =~ [/[:cntrl:]] ]] || [[ "${SAMPLE}" == "." ]] || [[ "${SAMPLE}" == ".." ]]; then
        echo "ERROR: --sample must be a simple name (no slashes, no '.' or '..'): '${SAMPLE}'" >&2
        exit 1
    fi

    # Validate KIT
    case "${KIT}" in
        rna001|rna002|rna004) ;;
        *)
            log_error "Invalid --kit '${KIT}'. Must be one of: rna001, rna002, rna004"
            exit 1
            ;;
    esac

    # Validate MODEL_TIER
    case "${MODEL_TIER}" in
        fast|hac|sup) ;;
        *)
            log_error "Invalid --model-tier '${MODEL_TIER}'. Must be one of: fast, hac, sup"
            exit 1
            ;;
    esac

    # Validate INPUT directory
    if [[ ! -d "${INPUT}" || ! -r "${INPUT}" ]]; then
        log_error "Input directory does not exist or is not readable: ${INPUT}"
        exit 4
    fi

    log_info "Arguments parsed: sample=${SAMPLE} input=${INPUT} kit=${KIT} output=${OUTPUT} threads=${THREADS} model-tier=${MODEL_TIER} device=${DEVICE} copy=${COPY_MODE} zstd=${ZSTD} force=${FORCE} keep-tmp=${KEEP_TMP} skip-qc=${SKIP_QC} prefer-pod5=${PREFER_POD5}"
}
