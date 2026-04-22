FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04
LABEL maintainer="Nanopore DRS Prep Pipeline"
LABEL description="Bundles dorado (two versions), slow5tools, blue-crab, pod5 for Nanopore DRS data prep"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── 1. System dependencies ─────────────────────────────────────────────────────
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget \
        curl \
        ca-certificates \
        pigz \
        bash \
        coreutils \
        findutils \
        gzip \
        xz-utils \
        python3 \
        python3-pip \
        python3-venv \
        zlib1g-dev \
        procps \
    && rm -rf /var/lib/apt/lists/*

# ── 2. Dorado (current) — used for RNA004 ─────────────────────────────────────
ARG DORADO_VERSION=1.4.0
RUN set -eux; \
    wget -q -O /tmp/dorado.tar.gz \
        "https://cdn.oxfordnanoportal.com/software/analysis/dorado-${DORADO_VERSION}-linux-x64.tar.gz"; \
    tar -xzf /tmp/dorado.tar.gz -C /opt/; \
    rm /tmp/dorado.tar.gz; \
    ln -s "/opt/dorado-${DORADO_VERSION}-linux-x64/bin/dorado" /usr/local/bin/dorado

# ── 3. Dorado (legacy) — used for RNA001 / RNA002 ─────────────────────────────
# dorado 0.9.6 is the last version that supports RNA002 basecalling and still
# accepts fast5 input (1.0.0 removed both).
ARG DORADO_LEGACY_VERSION=0.9.6
RUN set -eux; \
    wget -q -O /tmp/dorado-legacy.tar.gz \
        "https://cdn.oxfordnanoportal.com/software/analysis/dorado-${DORADO_LEGACY_VERSION}-linux-x64.tar.gz"; \
    tar -xzf /tmp/dorado-legacy.tar.gz -C /opt/; \
    rm /tmp/dorado-legacy.tar.gz; \
    ln -s "/opt/dorado-${DORADO_LEGACY_VERSION}-linux-x64/bin/dorado" /usr/local/bin/dorado-legacy

# ── 4. Dorado models (pre-downloaded to avoid runtime network access) ─────────
ENV DORADO_MODELS_DIR=/opt/dorado-models
# RNA004 models (three tiers) — downloaded with current dorado
RUN mkdir -p "${DORADO_MODELS_DIR}" \
    && dorado download --model rna004_130bps_hac@v5.2.0  --directory "${DORADO_MODELS_DIR}" \
    && dorado download --model rna004_130bps_fast@v5.2.0 --directory "${DORADO_MODELS_DIR}" \
    && dorado download --model rna004_130bps_sup@v5.2.0  --directory "${DORADO_MODELS_DIR}"
# RNA002 model — downloaded with legacy dorado (only hac variant exists for RNA002)
RUN dorado-legacy download --model rna002_70bps_hac@v3 --directory "${DORADO_MODELS_DIR}"

# ── 5. slow5tools 1.4.0 ───────────────────────────────────────────────────────
RUN set -eux; \
    wget -q -O /tmp/slow5tools.tar.gz \
        "https://github.com/hasindu2008/slow5tools/releases/download/v1.4.0/slow5tools-v1.4.0-x86_64-linux-binaries.tar.gz"; \
    tar -xzf /tmp/slow5tools.tar.gz -C /opt/; \
    rm /tmp/slow5tools.tar.gz; \
    ln -s /opt/slow5tools-v1.4.0-x86_64-linux-binaries/slow5tools /usr/local/bin/slow5tools

# ── 6. Python tools ───────────────────────────────────────────────────────────
RUN pip3 install --no-cache-dir \
        "pod5>=0.3.0" \
        "blue-crab>=0.1.0" \
        "NanoPlot>=1.42.0"

# ── 7. Pipeline code (last layer — changes most often) ────────────────────────
COPY lib/ /usr/local/lib/prep-drs/
COPY prep_drs.sh /usr/local/bin/prep_drs.sh
RUN chmod +x /usr/local/bin/prep_drs.sh /usr/local/lib/prep-drs/*.sh || true

# ── Runtime ───────────────────────────────────────────────────────────────────
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/prep_drs.sh"]
CMD ["--help"]
