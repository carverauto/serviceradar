# Build stage
FROM rust:latest AS builder

WORKDIR /usr/src/serviceradar-profiler

# Install eBPF and build dependencies
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    llvm \
    clang \
    libbpf-dev \
    linux-libc-dev \
    linux-headers-generic \
    pkg-config \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# The rust-toolchain.toml in profiler-ebpf will handle the nightly toolchain
# Just ensure we have rust-src available for the stable toolchain too
RUN rustup component add rust-src

# Install bpf-linker for eBPF linking
RUN cargo install bpf-linker

# Copy workspace files
COPY cmd/ebpf/profiler/Cargo.toml cmd/ebpf/profiler/Cargo.lock* ./
COPY cmd/ebpf/profiler/.cargo ./.cargo/
COPY cmd/ebpf/profiler/profiler ./profiler/
COPY cmd/ebpf/profiler/profiler-ebpf ./profiler-ebpf/
COPY cmd/ebpf/profiler/profiler-common ./profiler-common/
COPY cmd/ebpf/profiler/xtask ./xtask/
COPY proto ./proto/
COPY proto /usr/proto

# Build eBPF code first using xtask
# Use --locked to ensure we don't update dependencies
RUN RUSTUP_HOME=/usr/local/rustup cargo xtask build-ebpf --release || \
    (echo "eBPF build failed, retrying with verbose output" && \
     RUST_LOG=debug RUSTUP_HOME=/usr/local/rustup cargo xtask build-ebpf --release)

# Build the userspace profiler only (exclude eBPF package)
RUN cargo build --release --bin profiler -p profiler

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libbpf1 \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar-profiler/target/release/profiler /usr/local/bin/serviceradar-profiler
COPY --from=builder /usr/src/serviceradar-profiler/target/release/profiler /output/serviceradar-profiler

# Configuration and user setup
WORKDIR /etc/serviceradar
RUN mkdir -p profiler

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

# Generate example configuration (we'll need to create this file)
COPY packaging/profiler/config/profiler.toml ./profiler/profiler.toml

USER serviceradar
EXPOSE 8080

CMD ["/usr/local/bin/serviceradar-profiler", "--config", "/etc/serviceradar/profiler/profiler.toml"]