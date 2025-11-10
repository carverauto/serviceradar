# Build stage
FROM rust:latest AS builder

# Build from workspace root so path deps resolve (../../rust/kvutil)
WORKDIR /usr/src/serviceradar

# Install dependencies for building (protoc for tonic-build, and OpenSSL headers)
RUN apt-get update && apt-get install -y \
    protobuf-compiler \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Cache dependencies with real workspace contents
COPY Cargo.toml Cargo.lock ./
COPY cmd ./cmd
COPY rust ./rust
RUN cargo fetch --locked --manifest-path cmd/flowgger/Cargo.toml

# Build scripts need the proto definitions
COPY proto ./proto

# Build for x86_64-unknown-linux-gnu
RUN rustup target add x86_64-unknown-linux-gnu && \
    cargo build \
        --manifest-path cmd/flowgger/Cargo.toml \
        --locked \
        --no-default-features \
        --features "gelf nats-output passthrough rfc3164 rfc5424 syslog tls" \
        --release \
        --target x86_64-unknown-linux-gnu

# Runtime stage
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create output directory
RUN mkdir -p /output

# Copy the binary from the builder stage to both /usr/local/bin and /output
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-flowgger /usr/local/bin/serviceradar-flowgger
COPY --from=builder /usr/src/serviceradar/target/x86_64-unknown-linux-gnu/release/serviceradar-flowgger /output/serviceradar-flowgger
 
# Configuration and user setup
WORKDIR /etc/serviceradar
RUN mkdir -p /etc/serviceradar/templates
COPY packaging/flowgger/config/flowgger.toml /etc/serviceradar/templates/flowgger.toml
COPY packaging/flowgger/config/flowgger.toml /etc/serviceradar/flowgger.toml

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar

USER serviceradar
EXPOSE 514

ENTRYPOINT ["/usr/local/bin/serviceradar-flowgger"]
CMD ["/etc/serviceradar/flowgger.toml"]
