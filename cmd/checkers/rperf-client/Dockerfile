# Build stage
FROM rust:latest AS builder

WORKDIR /usr/src/serviceradar-rperf-checker

# Install dependencies for building
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Copy project files
COPY cmd/checkers/rperf-client/Cargo.toml cmd/checkers/rperf-client/Cargo.lock* ./
COPY cmd/checkers/rperf-client/src ./src/
COPY proto ./proto/
COPY cmd/checkers/rperf-client/build.rs ./

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --release --target x86_64-unknown-linux-gnu

# Runtime stage (for reference, not needed for .deb build)
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from the builder stage
COPY --from=builder /usr/src/rperf-grpc/target/x86_64-unknown-linux-gnu/release/serviceradar-rperf-checker /usr/local/bin/serviceradar-rperf-checker

# Configuration and user setup (optional for .deb runtime)
WORKDIR /etc/serviceradar/checkers
COPY cmd/checkers/rperf-client/config.json ./rperf.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar/checkers

USER serviceradar
EXPOSE 50059

CMD ["/usr/local/bin/serviceradar-rperf-checker", "--config", "/etc/serviceradar/checkers/rperf.json"]