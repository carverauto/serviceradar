# Build stage
FROM rust:latest AS builder

WORKDIR /usr/src/serviceradar-trapd

# Install dependencies for building
#RUN apt-get update && apt-get install -y \
#    protobuf-compiler \
#    && rm -rf /var/lib/apt/lists/*

# Copy project files
COPY cmd/trapd/Cargo.toml cmd/trapd/Cargo.lock* ./
COPY cmd/trapd/src ./src/
# COPY cmd/trapd/build.rs ./

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build --release --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar-trapd/target/x86_64-unknown-linux-gnu/release/serviceradar-trapd /usr/local/bin/serviceradar-trapd
COPY --from=builder /usr/src/serviceradar-trapd/target/x86_64-unknown-linux-gnu/release/serviceradar-trapd /output/serviceradar-trapd

# Configuration and user setup
WORKDIR /etc/serviceradar
COPY packaging/trapd/config/trapd.json ./trapd.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 50059

CMD ["/usr/local/bin/serviceradar-trapd", "/etc/serviceradar/trapd.json"]