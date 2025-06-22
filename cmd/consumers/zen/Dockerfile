# Build stage
FROM rust:latest AS builder

WORKDIR /usr/src/serviceradar-zen

# Install dependencies for building
#RUN apt-get update && apt-get install -y \
#    protobuf-compiler \
#    && rm -rf /var/lib/apt/lists/*

# Copy project files
COPY cmd/consumers/zen/Cargo.toml cmd/consumers/zen/Cargo.lock* ./
COPY cmd/consumers/zen/src ./src/
# COPY cmd/consumers/zen/build.rs ./

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --features nats-output --release --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

#RUN apt-get update && apt-get install -y \
#    libssl-dev \
#    ca-certificates \
#    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar-zen/target/x86_64-unknown-linux-gnu/release/serviceradar-zen /usr/local/bin/serviceradar-zen
COPY --from=builder /usr/src/serviceradar-zen/target/x86_64-unknown-linux-gnu/release/serviceradar-zen /output/serviceradar-zen

# Configuration and user setup
WORKDIR /etc/serviceradar
COPY packaging/zen/config/zen-consumer.json ./zen-consumer.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 50059

CMD ["/usr/local/bin/serviceradar-zen", "--config", "/etc/serviceradar/zen-consumer.json"]