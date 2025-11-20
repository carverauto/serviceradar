# Minimal ARC runner image with build tooling needed by ServiceRadar Bazel releases.
# Base image comes from GitHub Actions Runner from actions/runner project.
FROM ghcr.io/actions/actions-runner:latest

USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      flex \
      bison \
      perl \
      pkg-config \
      protobuf-compiler \
      libssl-dev; \
    rm -rf /var/lib/apt/lists/*

USER runner
