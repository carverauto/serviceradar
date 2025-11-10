# Build stage
FROM rust:latest AS builder

# Build from workspace root so path deps resolve (../../rust/kvutil)
WORKDIR /usr/src/serviceradar

# Install dependencies for building
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Cache dependencies: copy manifests first and fetch
COPY Cargo.toml ./
# Copy all workspace members' manifests to satisfy workspace resolution
COPY rust/kvutil/Cargo.toml ./rust/kvutil/Cargo.toml
COPY rust/config-bootstrap/Cargo.toml ./rust/config-bootstrap/Cargo.toml
COPY cmd/otel/Cargo.toml ./cmd/otel/Cargo.toml
COPY cmd/flowgger/Cargo.toml ./cmd/flowgger/Cargo.toml
COPY cmd/trapd/Cargo.toml ./cmd/trapd/Cargo.toml
COPY cmd/poller-ng/Cargo.toml ./cmd/poller-ng/Cargo.toml
COPY cmd/consumers/zen/Cargo.toml ./cmd/consumers/zen/Cargo.toml
RUN mkdir -p rust/kvutil/src rust/config-bootstrap/src cmd/flowgger/src cmd/trapd/src cmd/otel/src cmd/poller-ng/src && \
    printf "pub fn _stub(){}" > rust/kvutil/src/lib.rs && \
    printf "pub fn _stub(){}" > rust/config-bootstrap/src/lib.rs && \
    printf "fn main(){}" > cmd/trapd/src/main.rs && \
    printf "fn main(){}" > cmd/poller-ng/src/main.rs && \
    printf "fn main(){}" > cmd/flowgger/src/main.rs && \
    printf "pub fn _stub(){}" > cmd/flowgger/src/lib.rs && \
    printf "fn main(){}" > cmd/otel/src/main.rs && \
    printf "pub fn _stub(){}" > cmd/otel/src/lib.rs && \
    mkdir -p cmd/consumers/zen/src && \
    printf "fn main(){}" > cmd/consumers/zen/src/main.rs
RUN cargo fetch --manifest-path cmd/otel/Cargo.toml

# Now copy sources
COPY rust/kvutil ./rust/kvutil
COPY rust/config-bootstrap ./rust/config-bootstrap
COPY proto ./proto
COPY cmd/otel ./cmd/otel

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --manifest-path cmd/otel/Cargo.toml --release --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/otel /usr/local/bin/serviceradar-otel
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/otel /output/serviceradar-otel

# Configuration and user setup
WORKDIR /etc/serviceradar
RUN mkdir -p /etc/serviceradar/templates
COPY packaging/otel/config/otel.toml /etc/serviceradar/templates/otel.toml
COPY packaging/otel/config/otel.toml /etc/serviceradar/otel.toml

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 4317

ENTRYPOINT ["/usr/local/bin/serviceradar-otel"]
CMD ["--config", "/etc/serviceradar/otel.toml"]
