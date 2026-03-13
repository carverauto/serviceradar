# Minimal ARC runner image with build tooling needed by ServiceRadar Bazel releases.
# Base image comes from GitHub Actions Runner from actions/runner project.
# 2026-03-13: GitHub has deprecated runner v2.330.0; refresh to the current
# upstream image before rebuilding/pushing ghcr.io/carverauto/arc-runner.
FROM ghcr.io/actions/actions-runner@sha256:97b86689bb0571ca04b858e460190c8359c346c2fb4d093f0f88e40906e0b3c4

USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      flex \
      bison \
      gperf \
      m4 \
      perl \
      pkg-config \
      protobuf-compiler \
      libssl-dev \
      libncurses-dev \
      libreadline-dev \
      libffi-dev \
      libwxgtk3.2-dev \
      libgl1-mesa-dev \
      libglu1-mesa-dev \
      libpng-dev \
      libexpat1-dev \
      zlib1g-dev \
      curl \
      jq \
      rsync \
      tar \
      rpm; \
    rm -rf /var/lib/apt/lists/*

# Install cosign for container signing/attestation
ARG COSIGN_VERSION=v2.4.1
RUN curl -sSfL https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64 \
    -o /usr/local/bin/cosign && \
    chmod +x /usr/local/bin/cosign && \
    cosign version

# Install syft for SBOM generation
ARG SYFT_VERSION=v1.38.0
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | \
    sh -s -- -b /usr/local/bin ${SYFT_VERSION} && \
    syft version

USER runner
