#!/usr/bin/env bash
# Example invocations for prep_drs.sh
# Do NOT run this as-is; adjust paths to your data.

set -euo pipefail

IMAGE="${IMAGE:-prep-drs:latest}"
OUT="${OUT:-$PWD/drs_output}"
mkdir -p "${OUT}"

# Example 1: RNA002 fast5 (most common legacy case)
docker run --rm --gpus all \
  -v /data/run1/fast5:/in:ro \
  -v "${OUT}":/out \
  "${IMAGE}" \
  --sample SAMPLE_RNA002 \
  --input /in \
  --kit rna002 \
  --output /out

# Example 2: RNA004 pod5 (most common new case)
docker run --rm --gpus all \
  -v /data/run2/pod5:/in:ro \
  -v "${OUT}":/out \
  "${IMAGE}" \
  --sample SAMPLE_RNA004 \
  --input /in \
  --kit rna004 \
  --output /out

# Example 3: RNA002 pod5 (cross-format conversion)
# Script auto-converts pod5->fast5 for guppy.
docker run --rm --gpus all \
  -v /data/run3/pod5:/in:ro \
  -v "${OUT}":/out \
  "${IMAGE}" \
  --sample SAMPLE_RNA002_P \
  --input /in \
  --kit rna002 \
  --output /out \
  --copy \
  --threads 16

# Example 4: local (no Docker) -- requires all tools installed in PATH
# ./prep_drs.sh --sample TEST --input /data/run1/fast5 --kit rna002 --output ./out
