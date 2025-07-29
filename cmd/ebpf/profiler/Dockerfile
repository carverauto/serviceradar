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
    pkg-config \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy project files following ServiceRadar structure
COPY cmd/ebpf/profiler/Cargo.toml cmd/ebpf/profiler/Cargo.lock* ./
COPY cmd/ebpf/profiler/src ./src/
COPY cmd/ebpf/profiler/build.rs ./
COPY proto ./proto/
COPY proto /usr/proto

# Build with eBPF support for native architecture
RUN cargo build --release --features ebpf

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