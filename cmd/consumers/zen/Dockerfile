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

# Build from workspace root so path deps resolve
WORKDIR /usr/src/serviceradar

# Install dependencies for building
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Copy manifests and warm cache
COPY Cargo.toml ./
# Copy all workspace members' manifests
COPY rust/kvutil/Cargo.toml ./rust/kvutil/Cargo.toml
COPY cmd/flowgger/Cargo.toml ./cmd/flowgger/Cargo.toml
COPY cmd/trapd/Cargo.toml ./cmd/trapd/Cargo.toml
COPY cmd/otel/Cargo.toml ./cmd/otel/Cargo.toml
COPY cmd/poller-ng/Cargo.toml ./cmd/poller-ng/Cargo.toml
COPY cmd/consumers/zen/Cargo.toml ./cmd/consumers/zen/Cargo.toml
# Create stub targets to satisfy workspace validation
RUN mkdir -p rust/kvutil/src cmd/flowgger/src cmd/trapd/src cmd/otel/src cmd/poller-ng/src cmd/consumers/zen/src && \
    printf "pub fn _stub(){}" > rust/kvutil/src/lib.rs && \
    printf "fn main(){}" > cmd/trapd/src/main.rs && \
    printf "fn main(){}" > cmd/poller-ng/src/main.rs && \
    printf "fn main(){}" > cmd/flowgger/src/main.rs && \
    printf "pub fn _stub(){}" > cmd/flowgger/src/lib.rs && \
    printf "fn main(){}" > cmd/otel/src/main.rs && \
    printf "pub fn _stub(){}" > cmd/otel/src/lib.rs && \
    printf "fn main(){}" > cmd/consumers/zen/src/main.rs
RUN cargo fetch --manifest-path cmd/consumers/zen/Cargo.toml

# Now copy sources
COPY rust/kvutil ./rust/kvutil
COPY proto ./proto
COPY cmd/otel/proto ./cmd/otel/proto
COPY cmd/consumers/zen ./cmd/consumers/zen

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --manifest-path cmd/consumers/zen/Cargo.toml --release --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

#RUN apt-get update && apt-get install -y \
#    libssl-dev \
#    ca-certificates \
#    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-zen /usr/local/bin/serviceradar-zen
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-zen /output/serviceradar-zen
# Ship the zen-put-rule helper as well
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/zen-put-rule /usr/local/bin/zen-put-rule
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/zen-put-rule /output/zen-put-rule
COPY --from=configsync-builder /config-sync /usr/local/bin/config-sync
COPY docker/entrypoints/run-with-config-sync.sh /usr/local/bin/run-with-config-sync.sh
RUN chmod +x /usr/local/bin/run-with-config-sync.sh

# Configuration and user setup
WORKDIR /etc/serviceradar
RUN mkdir -p consumers /etc/serviceradar/templates/consumers
COPY packaging/zen/config/zen-consumer.json /etc/serviceradar/templates/consumers/zen-consumer.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 50040

ENV CONFIG_SERVICE="zen-consumer" \
    CONFIG_OUTPUT="/etc/serviceradar/consumers/zen-consumer.json" \
    CONFIG_TEMPLATE="/etc/serviceradar/templates/consumers/zen-consumer.json" \
    CONFIG_SYNC_ROLE=core

ENTRYPOINT ["/usr/local/bin/run-with-config-sync.sh"]
CMD ["/usr/local/bin/serviceradar-zen", "--config", "/etc/serviceradar/consumers/zen-consumer.json"]
