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
# Use --strip-components=1 so the extracted path is /opt/slow5tools/ regardless
# of the tarball's internal directory name (which has historically varied:
# slow5tools-v1.4.0/ vs slow5tools-v1.4.0-x86_64-linux-binaries/ vs ...).
# Also verify the binary actually runs so image build fails fast if broken.
RUN set -eux; \
    wget -q -O /tmp/slow5tools.tar.gz \
        "https://github.com/hasindu2008/slow5tools/releases/download/v1.4.0/slow5tools-v1.4.0-x86_64-linux-binaries.tar.gz"; \
    mkdir -p /opt/slow5tools; \
    tar -xzf /tmp/slow5tools.tar.gz -C /opt/slow5tools --strip-components=1; \
    rm /tmp/slow5tools.tar.gz; \
    ln -sf /opt/slow5tools/slow5tools /usr/local/bin/slow5tools; \
    /usr/local/bin/slow5tools --version

# ── 6. ONT VBZ HDF5 plugin ────────────────────────────────────────────────────
# ONT fast5 files since ~2020 are VBZ-compressed by default. dorado/dorado-legacy
# carry their own decoder, but slow5tools `f2s` reads fast5 via libhdf5 and
# needs the VBZ filter loaded via HDF5_PLUGIN_PATH. Without this the run
# explodes mid-conversion with:
#   [read_dataset::ERROR] The fast5 file is compressed with VBZ but the
#   required plugin is not loaded.
# Use the upstream Linux-x86_64 tarball (distro-agnostic) and extract the
# .so to a stable location, then point HDF5_PLUGIN_PATH at it.
# Recent ONT releases ship .deb only (no generic Linux tarball), so we extract
# the .so out of the amd64 deb with dpkg-deb -x rather than `dpkg -i` (avoids
# pulling in any deb-level deps we don't need).
ARG VBZ_VERSION=1.0.13
RUN set -eux; \
    wget -q -O /tmp/vbz.deb \
        "https://github.com/nanoporetech/vbz_compression/releases/download/${VBZ_VERSION}/ont-vbz-hdf-plugin_${VBZ_VERSION}_amd64.deb"; \
    mkdir -p /tmp/vbz_extract /opt/vbz; \
    dpkg-deb -x /tmp/vbz.deb /tmp/vbz_extract; \
    so_path="$(find /tmp/vbz_extract -name 'libvbz_hdf_plugin.so' -type f | head -n1)"; \
    test -n "${so_path}" || { echo "ERROR: libvbz_hdf_plugin.so not found in vbz deb" >&2; exit 1; }; \
    cp "${so_path}" /opt/vbz/; \
    rm -rf /tmp/vbz.deb /tmp/vbz_extract; \
    test -f /opt/vbz/libvbz_hdf_plugin.so
ENV HDF5_PLUGIN_PATH=/opt/vbz

# ── 7. Python tools ───────────────────────────────────────────────────────────
RUN pip3 install --no-cache-dir \
        "pod5>=0.3.0" \
        "blue-crab>=0.1.0" \
        "NanoPlot>=1.42.0"

# ── 8. Pipeline code (last layer — changes most often) ────────────────────────
COPY lib/ /usr/local/lib/prep-drs/
COPY prep_drs.sh /usr/local/bin/prep_drs.sh
RUN chmod +x /usr/local/bin/prep_drs.sh /usr/local/lib/prep-drs/*.sh || true

# ── Runtime ───────────────────────────────────────────────────────────────────
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/prep_drs.sh"]
CMD ["--help"]
