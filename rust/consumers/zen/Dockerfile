# Build stage
FROM rust:1.78-bullseye AS builder

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
COPY rust/config-bootstrap/Cargo.toml ./rust/config-bootstrap/Cargo.toml
COPY rust/edge-onboarding/Cargo.toml ./rust/edge-onboarding/Cargo.toml
COPY rust/flowgger/Cargo.toml ./rust/flowgger/Cargo.toml
COPY rust/trapd/Cargo.toml ./rust/trapd/Cargo.toml
COPY rust/otel/Cargo.toml ./rust/otel/Cargo.toml
COPY rust/log-collector/Cargo.toml ./rust/log-collector/Cargo.toml
COPY rust/flow-collector/Cargo.toml ./rust/flow-collector/Cargo.toml
COPY rust/bmp-collector/Cargo.toml ./rust/bmp-collector/Cargo.toml
COPY rust/srql/Cargo.toml ./rust/srql/Cargo.toml
COPY rust/consumers/zen/Cargo.toml ./rust/consumers/zen/Cargo.toml
COPY rust/rperf-client/Cargo.toml ./rust/rperf-client/Cargo.toml
# Create stub targets to satisfy workspace validation
RUN mkdir -p rust/kvutil/src rust/config-bootstrap/src rust/edge-onboarding/src \
             rust/flowgger/src rust/trapd/src rust/otel/src rust/log-collector/src \
             rust/flow-collector/src rust/bmp-collector/src rust/srql/src \
             rust/consumers/zen/src rust/rperf-client/src && \
    printf "pub fn _stub(){}" > rust/kvutil/src/lib.rs && \
    printf "pub fn _stub(){}" > rust/config-bootstrap/src/lib.rs && \
    printf "pub fn _stub(){}" > rust/edge-onboarding/src/lib.rs && \
    printf "fn main(){}" > rust/trapd/src/main.rs && \
    printf "pub fn _stub(){}" > rust/flowgger/src/lib.rs && \
    printf "pub fn _stub(){}" > rust/otel/src/lib.rs && \
    printf "fn main(){}" > rust/log-collector/src/main.rs && \
    printf "fn main(){}" > rust/flow-collector/src/main.rs && \
    printf "fn main(){}" > rust/bmp-collector/src/main.rs && \
    printf "pub fn _stub(){}" > rust/srql/src/lib.rs && \
    printf "fn main(){}" > rust/consumers/zen/src/main.rs && \
    printf "fn main(){}" > rust/rperf-client/src/main.rs
RUN cargo fetch --manifest-path rust/consumers/zen/Cargo.toml

# Now copy sources
COPY rust/kvutil ./rust/kvutil
COPY rust/config-bootstrap ./rust/config-bootstrap
COPY rust/edge-onboarding ./rust/edge-onboarding
COPY proto ./proto
COPY rust/otel/proto ./rust/otel/proto
COPY rust/consumers/zen ./rust/consumers/zen

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --manifest-path rust/consumers/zen/Cargo.toml --release --target x86_64-unknown-linux-gnu

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

# Configuration and user setup
WORKDIR /etc/serviceradar
RUN mkdir -p consumers /etc/serviceradar/templates/consumers
COPY build/packaging/zen/config/zen-consumer.json /etc/serviceradar/templates/consumers/zen-consumer.json
COPY build/packaging/zen/config/zen-consumer.json /etc/serviceradar/consumers/zen-consumer.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 50040

ENTRYPOINT ["/usr/local/bin/serviceradar-zen"]
CMD ["--config", "/etc/serviceradar/consumers/zen-consumer.json"]
