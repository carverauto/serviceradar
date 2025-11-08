# Build stage
FROM golang:1.22-bookworm AS configsync-builder
WORKDIR /workspace
COPY go.mod go.sum ./
COPY vendor ./vendor
COPY cmd ./cmd
COPY pkg ./pkg
COPY internal ./internal
COPY proto ./proto
RUN go env -w GOFLAGS="-mod=vendor" && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /config-sync ./cmd/tools/config-sync

# Build stage
FROM rust:latest AS builder

# Build from workspace root so path deps resolve (../../rust/kvutil)
WORKDIR /usr/src/serviceradar

# Install dependencies for building (protoc for tonic-build, and OpenSSL headers)
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
RUN cargo fetch --locked --manifest-path cmd/flowgger/Cargo.toml

# Build scripts need the proto definitions
COPY proto ./proto

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build \
        --manifest-path cmd/flowgger/Cargo.toml \
        --locked \
        --no-default-features \
        --features "gelf nats-output passthrough rfc3164 rfc5424 syslog tls" \
        --release \
        --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-flowgger /usr/local/bin/serviceradar-flowgger
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-flowgger /output/serviceradar-flowgger
COPY --from=configsync-builder /config-sync /usr/local/bin/config-sync
COPY docker/entrypoints/run-with-config-sync.sh /usr/local/bin/run-with-config-sync.sh
RUN chmod +x /usr/local/bin/run-with-config-sync.sh

# Configuration and user setup
WORKDIR /etc/serviceradar
RUN mkdir -p /etc/serviceradar/templates
COPY packaging/flowgger/config/flowgger.toml /etc/serviceradar/templates/flowgger.toml

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 514

ENV CONFIG_SERVICE=flowgger \
    CONFIG_OUTPUT=/etc/serviceradar/flowgger.toml \
    CONFIG_TEMPLATE=/etc/serviceradar/templates/flowgger.toml \
    CONFIG_SYNC_ROLE=core

ENTRYPOINT ["/usr/local/bin/run-with-config-sync.sh"]
CMD ["/usr/local/bin/serviceradar-flowgger", "/etc/serviceradar/flowgger.toml"]
