FROM ghcr.io/carverauto/custom-rust-zfs:latest AS proto-builder

WORKDIR /usr/src/serviceradar-sysmon-checker

# Copy proto files and project metadata
COPY src/proto ./src/proto/
COPY Cargo.toml Cargo.lock ./
COPY build.rs ./

# Create a minimal source to trigger proto generation
RUN mkdir -p src && \
    echo 'fn main() { println!("Dummy main"); }' > src/main.rs && \
    echo 'pub mod proto { pub use generated::*; mod generated { tonic::include_proto!("monitoring"); } }' > src/lib.rs && \
    # Build once to generate proto files
    cargo check --release --features zfs

# Second stage that uses the generated files from the first stage
FROM ghcr.io/carverauto/custom-rust-zfs:latest AS builder

WORKDIR /usr/src/serviceradar-sysmon-checker

# Copy project metadata
COPY Cargo.toml Cargo.lock ./
COPY build.rs ./

# Copy the generated target directory from proto-builder
COPY --from=proto-builder /usr/src/serviceradar-sysmon-checker/target ./target

# Copy all source files
COPY src ./src/

# Build the actual binary
RUN cargo build --release --features zfs

# Runtime stage for Linux deployment
FROM debian:bookworm AS runtime-linux

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    zfsutils-linux \
    && rm -rf /var/lib/apt/lists/*

# Copy Linux binary
COPY --from=builder /usr/src/serviceradar-sysmon-checker/target/release/serviceradar-sysmon-checker /usr/local/bin/serviceradar-sysmon-checker

# Configuration and user setup
WORKDIR /etc/serviceradar/checkers
# Create default sysmon.json
RUN echo '{"listen_addr":"0.0.0.0:50060","zfs":{"enabled":true,"pools":["rpool"],"include_datasets":true,"use_libzetta":true},"filesystems":[]}' > sysmon.json

RUN groupadd -r serviceradar && useradd -r -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar/checkers

USER serviceradar
EXPOSE 50060

CMD ["/usr/local/bin/serviceradar-sysmon-checker", "--config", "/etc/serviceradar/checkers/sysmon.json"]

# Output stage for collecting binaries
FROM scratch AS output

# Copy just the Linux binary
COPY --from=builder /usr/src/serviceradar-sysmon-checker/target/release/serviceradar-sysmon-checker /linux/serviceradar-sysmon-checker
