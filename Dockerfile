FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04
LABEL maintainer="Nanopore DRS Prep Pipeline"
LABEL description="Bundles guppy, dorado, slow5tools, blue-crab, pod5 for Nanopore DRS data prep"

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

# ── 2. Guppy 6.5.7 (OPTIONAL — ONT-gated distribution) ───────────────────────
# Pass a signed download URL at build time:
#   docker build --build-arg GUPPY_URL="https://..." .
# Or place ont-guppy_6.5.7_linux64.tar.gz in the build context beforehand.
# If neither is provided the layer prints a warning and continues; dorado covers
# RNA004 basecalling so guppy is not required for that workflow.
ARG GUPPY_URL=""
COPY ont-guppy_6.5.7_linux64.tar.gz* /tmp/
RUN set -eux; \
    GUPPY_ARCHIVE=""; \
    if [ -n "${GUPPY_URL}" ]; then \
        wget -q -O /tmp/ont-guppy_6.5.7_linux64.tar.gz "${GUPPY_URL}"; \
        GUPPY_ARCHIVE="/tmp/ont-guppy_6.5.7_linux64.tar.gz"; \
    elif FOUND=$(find /tmp -maxdepth 1 -name 'ont-guppy*.tar.gz' 2>/dev/null | head -1) && [ -n "${FOUND}" ]; then \
        GUPPY_ARCHIVE="${FOUND}"; \
    fi; \
    if [ -n "${GUPPY_ARCHIVE}" ]; then \
        mkdir -p /opt/ont-guppy; \
        tar -xzf "${GUPPY_ARCHIVE}" -C /opt/ont-guppy --strip-components=1; \
        rm -f "${GUPPY_ARCHIVE}"; \
        echo "Guppy installed to /opt/ont-guppy"; \
    else \
        echo "WARNING: Guppy tarball not found and GUPPY_URL not set — skipping guppy install." \
             "Pass --build-arg GUPPY_URL=<url> or place ont-guppy_6.5.7_linux64.tar.gz in the build context."; \
    fi

ENV PATH="/opt/ont-guppy/bin:${PATH}"

# ── 3. Dorado ─────────────────────────────────────────────────────────────────
ARG DORADO_VERSION=1.0.2
RUN set -eux; \
    wget -q -O /tmp/dorado.tar.gz \
        "https://cdn.oxfordnanoportal.com/software/analysis/dorado-${DORADO_VERSION}-linux-x64.tar.gz"; \
    tar -xzf /tmp/dorado.tar.gz -C /opt/; \
    rm /tmp/dorado.tar.gz; \
    ln -s "/opt/dorado-${DORADO_VERSION}-linux-x64/bin/dorado" /usr/local/bin/dorado

# ── 4. Dorado RNA004 models (pre-downloaded to avoid runtime network access) ──
ENV DORADO_MODELS_DIR=/opt/dorado-models
RUN mkdir -p "${DORADO_MODELS_DIR}" \
    && dorado download --model rna004_130bps_hac@v5.2.0  --directory "${DORADO_MODELS_DIR}" \
    && dorado download --model rna004_130bps_fast@v5.2.0 --directory "${DORADO_MODELS_DIR}" \
    && dorado download --model rna004_130bps_sup@v5.2.0  --directory "${DORADO_MODELS_DIR}"

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
        "blue-crab>=0.1.0"

# ── 7. Pipeline code (last layer — changes most often) ────────────────────────
COPY lib/ /usr/local/lib/prep-drs/
COPY prep_drs.sh /usr/local/bin/prep_drs.sh
RUN chmod +x /usr/local/bin/prep_drs.sh /usr/local/lib/prep-drs/*.sh || true

# ── Runtime ───────────────────────────────────────────────────────────────────
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/prep_drs.sh"]
CMD ["--help"]
