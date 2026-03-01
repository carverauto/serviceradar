# Build stage
FROM rust:1.78-bullseye AS builder

# Build from workspace root so path deps resolve (../../rust/kvutil)
WORKDIR /usr/src/serviceradar

# Install dependencies for building (protoc for tonic-build)
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Cache dependencies: copy manifests first and fetch
COPY Cargo.toml ./
# Copy all workspace members' manifests to satisfy workspace resolution
COPY rust/kvutil/Cargo.toml ./rust/kvutil/Cargo.toml
COPY rust/config-bootstrap/Cargo.toml ./rust/config-bootstrap/Cargo.toml
COPY rust/trapd/Cargo.toml ./rust/trapd/Cargo.toml
COPY rust/flowgger/Cargo.toml ./rust/flowgger/Cargo.toml
COPY rust/otel/Cargo.toml ./rust/otel/Cargo.toml
COPY rust/consumers/zen/Cargo.toml ./rust/consumers/zen/Cargo.toml
RUN mkdir -p rust/kvutil/src rust/config-bootstrap/src rust/flowgger/src rust/trapd/src rust/otel/src && \
    printf "pub fn _stub(){}" > rust/kvutil/src/lib.rs && \
    printf "pub fn _stub(){}" > rust/config-bootstrap/src/lib.rs && \
    printf "fn main(){}" > rust/trapd/src/main.rs && \
    printf "fn main(){}" > rust/flowgger/src/main.rs && \
    printf "pub fn _stub(){}" > rust/flowgger/src/lib.rs && \
    printf "fn main(){}" > rust/otel/src/main.rs && \
    printf "pub fn _stub(){}" > rust/otel/src/lib.rs && \
    mkdir -p rust/consumers/zen/src && \
    printf "fn main(){}" > rust/consumers/zen/src/main.rs
RUN cargo fetch --manifest-path rust/trapd/Cargo.toml

# Now copy sources
COPY rust/kvutil ./rust/kvutil
COPY rust/config-bootstrap ./rust/config-bootstrap
COPY proto ./proto
COPY rust/trapd ./rust/trapd

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --manifest-path rust/trapd/Cargo.toml --release --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-trapd /usr/local/bin/serviceradar-trapd
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-trapd /output/serviceradar-trapd

# Configuration and user setup
WORKDIR /etc/serviceradar
RUN mkdir -p /etc/serviceradar/templates
COPY build/packaging/trapd/config/trapd.json /etc/serviceradar/templates/trapd.json
COPY build/packaging/trapd/config/trapd.json /etc/serviceradar/trapd.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 162
EXPOSE 50056

ENTRYPOINT ["/usr/local/bin/serviceradar-trapd"]
CMD ["/etc/serviceradar/trapd.json"]
