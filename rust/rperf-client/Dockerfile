# Build stage
FROM rust:1.78-bullseye AS builder

WORKDIR /usr/src/serviceradar

# Install dependencies for building
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Copy workspace files so path dependencies resolve and the patched rperf
# binary is built from the same dependency graph as the checker.
COPY Cargo.toml Cargo.lock ./
COPY rust ./rust/
COPY third_party/rust_patches ./third_party/rust_patches/
COPY proto ./proto/

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build -p serviceradar-rperf-checker -p rperf --release --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-rperf-checker /usr/local/bin/serviceradar-rperf-checker
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-rperf-checker /output/serviceradar-rperf-checker
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/rperf /usr/local/bin/serviceradar-rperf
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/rperf /output/serviceradar-rperf

# Configuration and user setup
WORKDIR /etc/serviceradar/checkers
COPY build/packaging/rperf-checker/config/checkers/rperf.json ./rperf.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar/checkers

USER serviceradar
EXPOSE 50059

CMD ["/usr/local/bin/serviceradar-rperf-checker", "--config", "/etc/serviceradar/checkers/rperf.json"]
