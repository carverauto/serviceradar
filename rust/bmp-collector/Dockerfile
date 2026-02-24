# Build stage
FROM rustlang/rust:nightly AS builder

WORKDIR /usr/src/serviceradar

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    capnproto \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY arancini ./arancini
RUN cargo fetch --locked --manifest-path arancini/Cargo.toml

RUN cargo build \
        --manifest-path arancini/Cargo.toml \
        --locked \
        --release \
        -p arancini

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /output /var/lib/serviceradar /var/log/serviceradar

COPY --from=builder /usr/src/serviceradar/arancini/target/release/arancini /usr/local/bin/serviceradar-bmp-collector
COPY --from=builder /usr/src/serviceradar/arancini/target/release/arancini /output/serviceradar-bmp-collector

RUN groupadd -r -g 1001 serviceradar && useradd -r -u 1001 -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /var/lib/serviceradar /var/log/serviceradar

USER serviceradar

EXPOSE 11019/tcp

ENTRYPOINT ["/usr/local/bin/serviceradar-bmp-collector"]
CMD ["--bmp-address=0.0.0.0:11019", "--kafka-disable", "--nats-enable", "--nats-server=nats://127.0.0.1:4222", "--nats-subject=arancini.updates", "--nats-tls-required", "--nats-tls-ca-cert-path=/etc/serviceradar/certs/root.pem", "--nats-tls-client-cert-path=/etc/serviceradar/certs/bmp-collector.pem", "--nats-tls-client-key-path=/etc/serviceradar/certs/bmp-collector-key.pem", "--curation-state-path=/var/lib/serviceradar/state.bin"]
