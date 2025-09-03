# Build stage
FROM rust:latest AS builder

WORKDIR /usr/src/serviceradar-flowgger

# Install dependencies for building (protoc for tonic-build, and OpenSSL headers)
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy project files
COPY cmd/flowgger/Cargo.toml cmd/flowgger/Cargo.lock* ./
COPY cmd/flowgger/src ./src/
COPY cmd/flowgger/build.rs ./
COPY cmd/flowgger/proto ./proto/
COPY cmd/flowgger/kvutil ./kvutil/

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --features nats-output --release --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar-flowgger/target/x86_64-unknown-linux-gnu/release/serviceradar-flowgger /usr/local/bin/serviceradar-flowgger
COPY --from=builder /usr/src/serviceradar-flowgger/target/x86_64-unknown-linux-gnu/release/serviceradar-flowgger /output/serviceradar-flowgger

# Configuration and user setup
WORKDIR /etc/serviceradar
COPY packaging/flowgger/config/flowgger.toml ./flowgger.toml

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 514

CMD ["/usr/local/bin/serviceradar-flowgger", "/etc/serviceradar/flowgger.toml"]
