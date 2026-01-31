# Build stage
FROM rustlang/rust:nightly AS builder

# Build from workspace root so path deps resolve
WORKDIR /usr/src/serviceradar

# Install dependencies for building (protoc for tonic-build and OpenSSL headers)
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Cache dependencies with real workspace contents
COPY Cargo.toml Cargo.lock ./
COPY cmd ./cmd
COPY rust ./rust
RUN cargo fetch --locked --manifest-path rust/netflow-collector/Cargo.toml

# Build scripts need the proto definitions
COPY proto ./proto

# Build for native architecture (no cross-compilation)
RUN cargo build \
        --manifest-path rust/netflow-collector/Cargo.toml \
        --locked \
        --release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /output /var/lib/serviceradar /var/log/serviceradar

# Copy the binary from the builder stage
COPY --from=builder /usr/src/serviceradar/target/release/serviceradar-netflow-collector /usr/local/bin/serviceradar-netflow-collector
COPY --from=builder /usr/src/serviceradar/target/release/serviceradar-netflow-collector /output/serviceradar-netflow-collector

# Configuration and user setup
WORKDIR /etc/serviceradar
COPY rust/netflow-collector/netflow-collector.json /etc/serviceradar/netflow-collector.json

RUN groupadd -r -g 1001 serviceradar && useradd -r -u 1001 -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar /var/lib/serviceradar /var/log/serviceradar

USER serviceradar

# Expose NetFlow (2055), IPFIX (4739), and gRPC (50046) ports
EXPOSE 2055/udp 4739/udp 50046/tcp

ENTRYPOINT ["/usr/local/bin/serviceradar-netflow-collector"]
CMD ["--config", "/etc/serviceradar/netflow-collector.json"]
