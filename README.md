# prep-drs-data — Nanopore DRS raw-data preparation pipeline

> 🌐 **Language / 语言**: **English (current)** · [中文](README.zh.md)

A Bash pipeline that turns raw Nanopore Direct RNA Sequencing (DRS) data
(fast5 or pod5) into a clean, per-sample layout with merged FASTQ, merged
BLOW5 signal, a QC report, and the original raw files preserved. All
dependencies are bundled in a single Docker image.

---

## Table of contents

1. [Output layout](#output-layout)
2. [System requirements](#system-requirements)
3. [Tooling (all auto-installed)](#tooling-all-auto-installed)
4. [Build the Docker image](#build-the-docker-image)
5. [Run the pipeline](#run-the-pipeline)
6. [CLI reference](#cli-reference)
7. [Common scenarios](#common-scenarios)
8. [Running locally (without Docker)](#running-locally-without-docker)
9. [Running with Singularity / Apptainer](#running-with-singularity--apptainer)
10. [Batch processing](#batch-processing)
11. [Verifying outputs](#verifying-outputs)
12. [Troubleshooting](#troubleshooting)
13. [Exit codes](#exit-codes)
14. [Pipeline stages](#pipeline-stages)
15. [Project structure](#project-structure)
16. [Testing](#testing)
17. [Continuous integration / Docker Hub](#continuous-integration--docker-hub)

---

## Output layout

For a sample named `SAMPLE01`, the pipeline produces:

```
<output>/SAMPLE01/
├── fastq/
│   └── pass.fq.gz              # merged pass reads, gzip-compressed FASTQ
├── blow5/
│   └── nanopore.drs.blow5      # merged BLOW5 signal file
├── qc/                         # QC report (disable with --skip-qc)
│   ├── nanoplot/
│   │   ├── NanoPlot-report.html  # interactive HTML QC report
│   │   ├── NanoStats.txt         # read count, length, quality stats
│   │   └── *.png                 # length / quality distribution plots
│   ├── blow5_stats.txt         # output of `slow5tools stats`
│   └── qc_report.md            # consolidated Markdown summary
└── fast5/    ← or pod5/        # the original raw files (moved or copied)
```

Top-level directory = sample name, second level = `fastq/` / `blow5/` /
`qc/` / (`fast5/` or `pod5/`).

---

## System requirements

| Item | Requirement |
|------|-------------|
| OS | Linux (Ubuntu 20.04 / 22.04 recommended) |
| GPU | NVIDIA GPU, Pascal or newer, ≥ 8 GB VRAM recommended |
| Driver | NVIDIA driver ≥ 525 (CUDA 11.8 compatible) |
| Docker | 20.10+ |
| NVIDIA Container Toolkit | installed & configured |
| Disk | ≥ 3× the raw input size of free space |
| RAM | ≥ 16 GB |

**Verify GPU access:**

```bash
# host
nvidia-smi

# inside Docker
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```

Both commands must print GPU info for the pipeline to work.

---

## Tooling (all auto-installed)

The Dockerfile installs every dependency automatically. **No manual downloads,
no ONT Community login required.**

| Tool | Version | Used for |
|------|---------|----------|
| `dorado` | 1.4.0 | RNA004 basecalling |
| `dorado-legacy` | 0.9.6 | RNA001 / RNA002 basecalling (last version that supports RNA002 and accepts fast5 natively) |
| dorado RNA004 models | `rna004_130bps_{fast,hac,sup}@v5.2.0` | pre-downloaded into the image |
| dorado RNA002 model | `rna002_70bps_hac@v3` | pre-downloaded (only `hac` exists for RNA002) |
| `slow5tools` | 1.4.0 | fast5 → BLOW5, merge, stats, quickcheck |
| `blue-crab` | pip latest | pod5 → BLOW5 direct conversion |
| `pod5` | pip latest | fast5 → pod5 (only needed for RNA004 + fast5 input) |
| `NanoPlot` | ≥ 1.42.0 | read-level QC report |
| `pigz` | apt | parallel gzip compression |

> Why two dorado versions? `dorado` ≥ 1.0.0 dropped RNA002 support and stopped
> accepting fast5 input. `dorado-legacy` 0.9.6 is the last release that
> handles both, and it is publicly available on the ONT CDN (unlike the
> archived guppy, which needs an ONT Community account).

---

## Build the Docker image

```bash
cd /path/to/prep-drs-data
docker build -t prep-drs:latest .
```

Build takes roughly **15–40 minutes**, dominated by:

- downloading dorado 1.4.0 (~300 MB)
- downloading dorado 0.9.6 legacy (~250 MB)
- downloading the three RNA004 models (~2–4 GB, baked into the image — no
  network access needed at runtime)
- downloading the RNA002 model (~30 MB)
- downloading slow5tools (~50 MB)
- `pip install pod5 blue-crab NanoPlot`

Final image size: **~9–13 GB**.

**Verify the build:**

```bash
docker run --rm prep-drs:latest --help
```

Should print `Usage: prep_drs.sh --sample NAME ...` and exit 0.

### Pulling from Docker Hub

If you do not want to build locally, pull the pre-built image (see
[Continuous integration / Docker Hub](#continuous-integration--docker-hub)
for how the image is published):

```bash
docker pull <your-docker-hub-user>/prep-drs-data:latest
```

---

## Run the pipeline

### Invocation template

```bash
docker run --rm --gpus all \
  -v /host/raw_input:/in:ro \
  -v /host/output:/out \
  prep-drs:latest \
  --sample <sample_name> \
  --input /in \
  --kit <rna001|rna002|rna004> \
  --output /out
```

| Docker flag | Meaning |
|-------------|---------|
| `--rm` | remove the container after it exits |
| `--gpus all` | expose all host GPUs (required for basecalling) |
| `-v /host:/in:ro` | mount raw-data directory read-only at `/in` |
| `-v /host:/out` | mount output directory read-write at `/out` |

---

## CLI reference

### Required

| Flag | Description |
|------|-------------|
| `--sample NAME` | sample name (becomes the top-level output directory) |
| `--input DIR` | directory to recursively scan for `*.fast5` or `*.pod5` |
| `--kit KIT` | `rna001` / `rna002` / `rna004` |
| `--output DIR` | output root directory |

### Optional

| Flag | Default | Description |
|------|---------|-------------|
| `--threads N` | `nproc` | parallelism for slow5tools merge, pigz, NanoPlot, etc. |
| `--model-tier T` | `hac` | basecalling accuracy tier: `fast` / `hac` / `sup` (RNA002 only has `hac`) |
| `--device D` | `cuda:0` | GPU device (multi-GPU: `cuda:0,cuda:1`) |
| `--copy` | off | copy raw files instead of moving them (doubles disk usage but leaves the source directory untouched) |
| `--zstd` | off | use zstd compression for BLOW5 (default is zlib, wider tool compatibility) |
| `--force` | off | re-run even if outputs already exist |
| `--keep-tmp` | off | keep `.tmp/` workspace (for debugging) |
| `--skip-qc` | off | skip the NanoPlot + slow5tools stats QC report |
| `--help` | — | print help and exit |

> **Security note on `--sample`**: the value must be a simple directory name.
> Slashes, `.`, `..`, and control characters are rejected (exit code 1) to
> prevent path traversal.

---

## Common scenarios

### Scenario 1 — RNA002, fast5 input (most common legacy case)

```bash
docker run --rm --gpus all \
  -v /data/seq/run_2023_05:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample PatientA_RNA002 \
  --input /in \
  --kit rna002 \
  --output /out
```

Expected output: `/data/drs_prep/PatientA_RNA002/{fastq,blow5,qc,fast5}/`.

### Scenario 2 — RNA004, pod5 input (most common current case)

```bash
docker run --rm --gpus all \
  -v /data/seq/run_2025_03:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample PatientB_RNA004 \
  --input /in \
  --kit rna004 \
  --output /out \
  --model-tier sup \
  --threads 32
```

### Scenario 3 — RNA002 with pod5 input

`dorado-legacy` 0.9.6 accepts pod5 natively, so no format conversion is
needed:

```bash
docker run --rm --gpus all \
  -v /data/seq/run_2024_08:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample SampleC_RNA002 \
  --input /in \
  --kit rna002 \
  --output /out \
  --copy
```

### Scenario 4 — RNA004 with fast5 input (uncommon)

Current `dorado` requires pod5, so the pipeline auto-converts fast5 → pod5
first:

```bash
docker run --rm --gpus all \
  -v /data/old_rna004_fast5:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample SampleD_RNA004 \
  --input /in \
  --kit rna004 \
  --output /out
```

---

## Running locally (without Docker)

If the host has every dependency on `PATH` (`dorado`, `dorado-legacy`,
`slow5tools`, `blue-crab`, `pod5`, `pigz`, `NanoPlot`), run the script
directly:

```bash
cd /path/to/prep-drs-data
./prep_drs.sh \
  --sample TEST01 \
  --input /data/raw_fast5 \
  --kit rna002 \
  --output ./output
```

It will auto-locate `./lib/` alongside the script.

Which tools are actually required depends on the input format and kit:

| Kit | Input | Required tools |
|-----|-------|---------------|
| rna001 / rna002 | fast5 | `dorado-legacy`, `slow5tools`, `pigz`, `NanoPlot` |
| rna001 / rna002 | pod5 | `dorado-legacy`, `slow5tools`, `blue-crab`, `pigz`, `NanoPlot` |
| rna004 | pod5 | `dorado`, `slow5tools`, `blue-crab`, `pigz`, `NanoPlot` |
| rna004 | fast5 | `dorado`, `slow5tools`, `pod5`, `pigz`, `NanoPlot` |

> `NanoPlot` is only needed when `--skip-qc` is not passed.

---

## Running with Singularity / Apptainer

HPC clusters usually disallow Docker. Singularity (now Apptainer) can pull
the same image from Docker Hub and runs it with minor flag differences.

| Docker | Singularity / Apptainer |
|--------|-------------------------|
| `--gpus all` | `--nv` |
| `-v host:container[:ro]` | `-B host:container[:ro]` (or `--bind`) |
| container rootfs writable | read-only by default (outputs must go to a bind mount) |

### Pull the image (once)

```bash
# Creates prep-drs.sif (~9–13 GB)
singularity pull prep-drs.sif docker://<your-docker-hub-user>/prep-drs-data:latest
```

You can also run `docker://...` directly without a `.sif`, but it re-extracts
every time.

### Run one sample

```bash
singularity run --nv \
  -B /data/seq/run_2025_03:/in:ro \
  -B /data/drs_prep:/out \
  prep-drs.sif \
  --sample PatientB_RNA004 \
  --input /in \
  --kit rna004 \
  --output /out
```

The Dockerfile's `ENTRYPOINT ["/usr/local/bin/prep_drs.sh"]` is honoured by
`singularity run`, so arguments after the image name are passed straight to
`prep_drs.sh`.

### SLURM template

```bash
#!/bin/bash
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=32
#SBATCH --mem=64G
#SBATCH --time=12:00:00

module load singularity    # or apptainer, depending on the cluster

SIF=/shared/images/prep-drs.sif
IN=/scratch/$USER/run_2025_03
OUT=/scratch/$USER/drs_prep

singularity run --nv \
  -B "${IN}":/in:ro \
  -B "${OUT}":/out \
  "${SIF}" \
  --sample "${SLURM_JOB_NAME}" \
  --input /in \
  --kit rna004 \
  --output /out \
  --threads "${SLURM_CPUS_PER_TASK}"
```

### Common pitfalls

1. **GPU invisible**: `--nv` missing, or the node lacks `nvidia-container-cli`.
   Sanity check with `singularity exec --nv prep-drs.sif nvidia-smi`.
2. **`$HOME` / `$PWD` auto-bind shadows container paths**: use `--no-home` or
   `--containall` for stricter isolation.
3. **Cache fills up `~/.singularity/cache`**: clean with
   `singularity cache clean` after the first pull.
4. **Cannot write to `/out`**: the container runs as the host UID, not as
   root. Make sure the bind-mounted host directory is writable by your user.
5. **`.tmp/` placement**: `prep_drs.sh` puts `.tmp/` under
   `${OUTPUT}/${SAMPLE}/.tmp`, so as long as `/out` is writable no extra
   bind is needed.

---

## Batch processing

Each invocation handles one sample. Process many with a small wrapper:

```bash
#!/usr/bin/env bash
# batch_run.sh
set -euo pipefail

IMAGE=prep-drs:latest
OUTPUT=/data/drs_prep

declare -A SAMPLES=(
  ["PatientA"]="/data/raw/runA:rna002"
  ["PatientB"]="/data/raw/runB:rna004"
  ["PatientC"]="/data/raw/runC:rna002"
)

for sample in "${!SAMPLES[@]}"; do
  IFS=':' read -r input_dir kit <<< "${SAMPLES[$sample]}"
  echo ">>> Processing ${sample} (${kit})"

  docker run --rm --gpus all \
    -v "${input_dir}":/in:ro \
    -v "${OUTPUT}":/out \
    "${IMAGE}" \
    --sample "${sample}" \
    --input /in \
    --kit "${kit}" \
    --output /out \
    --copy
done
```

The pipeline is **idempotent**: if all final outputs already exist, it
exits 0 and does nothing. Re-running after a partial failure is safe.
Use `--force` to override.

---

## Verifying outputs

### FASTQ

```bash
gzip -t /out/SAMPLE01/fastq/pass.fq.gz && echo OK
zcat /out/SAMPLE01/fastq/pass.fq.gz | head -8
echo $(( $(zcat /out/SAMPLE01/fastq/pass.fq.gz | wc -l) / 4 ))  # read count
```

### BLOW5

```bash
slow5tools quickcheck /out/SAMPLE01/blow5/nanopore.drs.blow5 && echo OK
slow5tools stats      /out/SAMPLE01/blow5/nanopore.drs.blow5
```

### Raw files

```bash
ls /out/SAMPLE01/fast5/ | head      # or pod5/
du -sh /out/SAMPLE01/*/             # size of each sub-directory
```

### QC report

```bash
# Markdown summary
cat /out/SAMPLE01/qc/qc_report.md

# Open HTML report in a browser
xdg-open /out/SAMPLE01/qc/nanoplot/NanoPlot-report.html
```

To skip QC entirely (saves a few minutes on very large samples):

```bash
docker run --rm --gpus all \
  -v /data/in:/in:ro -v /data/out:/out \
  prep-drs:latest \
  --sample SAMPLE01 --input /in --kit rna004 --output /out \
  --skip-qc
```

---

## Troubleshooting

### `nvidia-smi: not available` (exit code 3)

**Cause:** the container has no GPU.

**Fix:**
1. Check `nvidia-smi` works on the host.
2. Install NVIDIA Container Toolkit: `sudo apt install nvidia-container-toolkit && sudo systemctl restart docker`.
3. Always pass `--gpus all` to `docker run`.

### `Mixed input formats` / `no fast5 or pod5 files found` (exit code 4)

**Cause:** the `--input` directory contains both fast5 and pod5, or neither.

**Fix:** separate the formats into different directories and run each as its
own sample, or delete the format you do not want.

### `dorado-legacy: command not found`

**Cause:** the image was built incorrectly or has been modified. The Dockerfile
is expected to install `dorado-legacy` 0.9.6 automatically.

**Fix:** rebuild the image and confirm the `dorado-legacy` download step
succeeded.

### `dorado: model download failed`

**Cause:** no network during image build.

**Fix:** build on a machine with internet, then move the image with
`docker save prep-drs:latest > prep-drs.tar` / `docker load`.

### `mv: cannot move ... : Invalid cross-device link`

**Cause:** `--input` and `--output` live on different filesystems; `mv`
cannot cross mount points.

**Fix:** pass `--copy`, or put the input and output on the same filesystem.

### Out of disk space

**Cause:** pod5 ↔ fast5 conversion, basecalling, and BLOW5 merge all need
scratch space under `.tmp/`.

**Fix:** make sure the `--output` disk has at least **3× the raw input
size** free.

### `--sample` rejected

**Cause:** the sample name contains `/`, `.`, `..`, or control characters
(path-traversal guard).

**Fix:** use only letters, digits, underscore, and hyphen.

### dorado runs very slowly

**Possible causes:**
- `--model-tier sup` is the most accurate but slowest model.
- GPU is busy with another process — check `nvidia-smi`.

**Speed-ups:**
- switch to `--model-tier hac` (default) or `fast`
- increase `--threads`
- use multiple GPUs: `--device cuda:0,cuda:1`

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | argument error |
| 2 | missing dependency |
| 3 | no GPU / `nvidia-smi` failed |
| 4 | input error (empty, mixed formats, unreadable) |
| 5 | basecalling failed |
| 6 | signal-format conversion failed |
| 7 | integrity check failed (`gzip -t` or `slow5tools quickcheck`) |
| 8 | raw-file move/copy failed |
| 9 | QC report generation failed (NanoPlot or slow5tools stats) |

These are stable, so scripts can branch on them: `if [[ $? -eq 5 ]]; then ...; fi`.

---

## Pipeline stages

`prep_drs.sh` runs these stages in order; any failure aborts immediately:

1. **Argument parsing & validation** — required flags, kit, model tier, sample-name safety.
2. **Dependency & GPU check** — tools depend on kit + input format; `nvidia-smi` must work.
3. **Input-format detection** — recursive counts of `*.fast5` / `*.pod5`; picks a branch.
4. **Output directory prep** — creates `fastq/`, `blow5/`, `qc/`, `fast5/` or `pod5/`, `.tmp/`; skips idempotently if outputs already exist (use `--force` to re-run).
5. **Basecalling**
   - RNA001 / RNA002 → `dorado-legacy` 0.9.6 (accepts fast5 and pod5 natively, no pre-conversion)
   - RNA004 → `dorado` 1.4 (auto-converts fast5 → pod5 first if needed)
6. **FASTQ output** — dorado / dorado-legacy streams `--emit-fastq` through pigz to `pass.fq.gz`.
7. **FASTQ integrity check** — `gzip -t`.
8. **Signal → BLOW5** — fast5 via `slow5tools f2s`, pod5 via `blue-crab p2s`.
9. **BLOW5 merge** — `slow5tools merge` → single `nanopore.drs.blow5`.
10. **BLOW5 integrity check** — `slow5tools quickcheck`.
11. **QC report** — `NanoPlot` for the FASTQ + `slow5tools stats` for the BLOW5, consolidated into `qc/qc_report.md` (skip with `--skip-qc`).
12. **Raw-file placement** — move (default) or `--copy` the original `*.fast5` / `*.pod5` into the `fast5/` / `pod5/` directory.
13. **Cleanup** — remove `.tmp/` (unless `--keep-tmp`), print wall-clock time and output manifest.

---

## Project structure

```
prep-drs-data/
├── prep_drs.sh                    # main entry-point
├── lib/
│   ├── utils.sh                   # logging, argument parsing, GPU/input checks
│   ├── basecall.sh                # dorado + dorado-legacy wrappers, fast5→pod5
│   ├── signal_convert.sh          # slow5tools + blue-crab wrappers, integrity checks
│   └── qc.sh                      # NanoPlot + slow5tools stats, qc_report.md generator
├── Dockerfile                     # bundles every dependency
├── .dockerignore
├── README.md                      # this file (English)
├── README.zh.md                   # Chinese version (中文版)
├── .github/
│   └── workflows/
│       └── docker-publish.yml     # GitHub Actions → Docker Hub auto-publish
├── examples/
│   └── run_example.sh             # four example invocations
└── test/
    ├── test_cli.sh                # 19 CLI smoke tests (no GPU required)
    └── fixtures/
        └── README.md              # how to stage real DRS data for end-to-end tests
```

---

## Testing

### Smoke tests (no GPU, no real data required)

```bash
cd /path/to/prep-drs-data
bash test/test_cli.sh
```

Covers argument parsing, help text, path-traversal protection, and input
validation. Expect **19/19 passing**.

### End-to-end testing (needs GPU and real data)

See `test/fixtures/README.md`. Small DRS samples can be taken from
[ONT open datasets](https://github.com/nanoporetech/ont_open_datasets),
placed under `test/fixtures/`, and run through the full pipeline.

---

## Continuous integration / Docker Hub

`.github/workflows/docker-publish.yml` builds and publishes the Docker image
automatically:

- on every `push` to `main` → tags `latest`, `main`, `sha-<short>`
- on every `push` of a `v*` git tag (e.g. `v1.2.0`) → tag `<tag-name>`
- on-demand via the **Run workflow** button in the Actions tab

Image name: `${DOCKER_HUB_USER}/prep-drs-data`, where `DOCKER_HUB_USER` is a
repository secret.

### One-time setup

Add two repository secrets at **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `DOCKER_HUB_USER`  | your Docker Hub username |
| `DOCKER_HUB_TOKEN` | a Docker Hub [access token](https://hub.docker.com/settings/security) (do **not** use your password) |

Token permissions should be **Read, Write, Delete**.

### Pulling the published image

```bash
docker pull <your-docker-hub-user>/prep-drs-data:latest
docker run --rm --gpus all \
  -v /data/in:/in:ro -v /data/out:/out \
  <your-docker-hub-user>/prep-drs-data:latest \
  --sample SAMPLE01 --input /in --kit rna004 --output /out
```

### Disk-space note for GitHub-hosted runners

The final image is ~9–13 GB, while a standard GitHub Actions runner ships
with ~14 GB free disk. The workflow includes a cleanup step that frees about
8 GB by removing the pre-installed .NET SDK, Android SDK, GHC, and CodeQL
bundles. If you fork and still see `no space left on device`, consider:

- using a self-hosted runner (recommended for production use)
- removing the pre-downloaded models from the image and mounting them at runtime

---

## Version matrix

| Component | Version |
|-----------|---------|
| Docker base | `nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04` |
| `dorado` (current, RNA004) | 1.4.0 |
| `dorado-legacy` (RNA001/RNA002) | 0.9.6 (last release that supports RNA002 and fast5 input) |
| dorado RNA004 models | `rna004_130bps_{fast,hac,sup}@v5.2.0` |
| dorado RNA002 model | `rna002_70bps_hac@v3` (only `hac` tier exists, downloaded via legacy) |
| slow5tools | 1.4.0 |
| blue-crab | pip latest |
| pod5 | pip latest |
| NanoPlot | ≥ 1.42.0 |

---

## Acknowledgements

- [Oxford Nanopore Technologies](https://nanoporetech.com/) — dorado, pod5
- [hasindu2008/slow5tools](https://github.com/hasindu2008/slow5tools) — fast5 → BLOW5 conversion and merging
- [Psy-Fer/blue-crab](https://github.com/Psy-Fer/blue-crab) — pod5 → BLOW5 direct conversion
- [wdecoster/NanoPlot](https://github.com/wdecoster/NanoPlot) — Nanopore reads QC visualisation

---

## License

See `LICENSE`.
