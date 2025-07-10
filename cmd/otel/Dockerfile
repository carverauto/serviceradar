# Build stage
FROM rust:latest AS builder

WORKDIR /usr/src/serviceradar-otel

# Install dependencies for building
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Copy project files
COPY cmd/otel/Cargo.toml cmd/otel/Cargo.lock* ./
COPY cmd/otel/src ./src/
COPY cmd/otel/build.rs ./
COPY cmd/otel/proto ./proto/

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
COPY --from=builder /usr/src/serviceradar-otel/target/x86_64-unknown-linux-gnu/release/otel /usr/local/bin/serviceradar-otel
COPY --from=builder /usr/src/serviceradar-otel/target/x86_64-unknown-linux-gnu/release/otel /output/serviceradar-otel

# Configuration and user setup
WORKDIR /etc/serviceradar

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 4317

CMD ["/usr/local/bin/serviceradar-otel"]