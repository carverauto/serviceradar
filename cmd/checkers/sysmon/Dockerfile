# Build stage for protocol buffers
FROM ghcr.io/carverauto/custom-rust-zfs:latest AS proto-builder

WORKDIR /usr/src/serviceradar-sysmon-checker
COPY cmd/checkers/sysmon/src/proto ./src/proto/
COPY cmd/checkers/sysmon/Cargo.toml cmd/checkers/sysmon/Cargo.lock ./
COPY cmd/checkers/sysmon/build.rs ./
# Copy workspace dependencies
COPY rust/edge-onboarding ../rust/edge-onboarding/
COPY rust/config-bootstrap ../rust/config-bootstrap/
COPY rust/kvutil ../rust/kvutil/
RUN mkdir -p src && \
    echo 'fn main() { println!("Dummy main"); }' > src/main.rs && \
    echo 'pub mod proto { pub use generated::*; mod generated { tonic::include_proto!("monitoring"); } }' > src/lib.rs && \
    cargo check --release

# Build stage for binaries
FROM ghcr.io/carverauto/custom-rust-zfs:latest AS builder

WORKDIR /usr/src/serviceradar-sysmon-checker
COPY cmd/checkers/sysmon/Cargo.toml cmd/checkers/sysmon/Cargo.lock ./
COPY cmd/checkers/sysmon/build.rs ./
# Copy workspace dependencies
COPY rust/edge-onboarding ../rust/edge-onboarding/
COPY rust/config-bootstrap ../rust/config-bootstrap/
COPY rust/kvutil ../rust/kvutil/
COPY --from=proto-builder /usr/src/serviceradar-sysmon-checker/target ./target
COPY cmd/checkers/sysmon/src ./src/

# Build ZFS-enabled binary
RUN cargo build --release --features zfs --verbose && \
    ls -l target/release/ && \
    [ -f target/release/serviceradar-sysmon-checker ] || { echo "Error: ZFS binary not produced"; exit 1; } && \
    mv target/release/serviceradar-sysmon-checker target/release/serviceradar-sysmon-checker-zfs && \
    ls -l target/release/

# Build non-ZFS binary
RUN cargo build --release --verbose && \
    ls -l target/release/ && \
    [ -f target/release/serviceradar-sysmon-checker ] || { echo "Error: Non-ZFS binary not produced"; exit 1; } && \
    mv target/release/serviceradar-sysmon-checker target/release/serviceradar-sysmon-checker-nonzfs && \
    ls -l target/release/

# Runtime stage
FROM debian:bookworm-slim AS runtime-linux

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy both binaries and verify
COPY --from=builder /usr/src/serviceradar-sysmon-checker/target/release/serviceradar-sysmon-checker-zfs /usr/local/bin/
COPY --from=builder /usr/src/serviceradar-sysmon-checker/target/release/serviceradar-sysmon-checker-nonzfs /usr/local/bin/
RUN ls -l /usr/local/bin/ && \
    [ -f /usr/local/bin/serviceradar-sysmon-checker-zfs ] || { echo "Error: ZFS binary not copied to /usr/local/bin/"; exit 1; } && \
    [ -f /usr/local/bin/serviceradar-sysmon-checker-nonzfs ] || { echo "Error: Non-ZFS binary not copied to /usr/local/bin/"; exit 1; }

# Configuration and user setup
WORKDIR /etc/serviceradar/checkers
RUN echo '{"listen_addr":"0.0.0.0:50083","security":{"mode":"none"},"poll_interval":30,"zfs":null,"filesystems":[{"name":"/","type":"ext4","monitor":true}]}' > sysmon.json.example

# Create directories for edge onboarding
RUN mkdir -p /var/lib/serviceradar/checker/certs /var/lib/serviceradar/checker/config

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar/checkers /var/lib/serviceradar

# Environment variables for edge onboarding
ENV ONBOARDING_TOKEN=""
ENV CORE_API_URL=""
ENV KV_ENDPOINT=""

USER serviceradar
EXPOSE 50083

# Entrypoint supports edge onboarding or traditional config
# If ONBOARDING_TOKEN is set, use edge onboarding (no --config needed)
# Otherwise, use traditional config file
CMD ["/bin/sh", "-c", "\
    BINARY=/usr/local/bin/serviceradar-sysmon-checker-nonzfs; \
    if [ \"$USE_ZFS\" = \"true\" ] && command -v zfs >/dev/null 2>&1; then \
        BINARY=/usr/local/bin/serviceradar-sysmon-checker-zfs; \
    fi; \
    if [ -n \"$ONBOARDING_TOKEN\" ]; then \
        exec $BINARY; \
    else \
        exec $BINARY --config /etc/serviceradar/checkers/sysmon.json; \
    fi"]

FROM scratch AS output

# Copy both binaries to the output directory
COPY --from=builder /usr/src/serviceradar-sysmon-checker/target/release/serviceradar-sysmon-checker-nonzfs /output/serviceradar-sysmon-checker-nonzfs
COPY --from=builder /usr/src/serviceradar-sysmon-checker/target/release/serviceradar-sysmon-checker-zfs /output/serviceradar-sysmon-checker-zfs
# Also copy the non-ZFS one as the default for backward compatibility
COPY --from=builder /usr/src/serviceradar-sysmon-checker/target/release/serviceradar-sysmon-checker-nonzfs /output/serviceradar-sysmon-checker
