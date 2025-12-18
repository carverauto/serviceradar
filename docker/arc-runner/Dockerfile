# Minimal ARC runner image with build tooling needed by ServiceRadar Bazel releases.
# Base image comes from GitHub Actions Runner from actions/runner project.
FROM ghcr.io/actions/actions-runner@sha256:25e5339f41c8511899dff6d9d1ee3d29d0aaca085f24b967f486e153e4368cc6

USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      flex \
      bison \
      gperf \
      perl \
      pkg-config \
      protobuf-compiler \
      libssl-dev \
      curl \
      jq \
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
