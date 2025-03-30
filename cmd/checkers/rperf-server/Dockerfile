# Build stage
FROM rust:latest AS builder

WORKDIR /usr/src/rperf

# Install dependencies (if any are needed beyond Rust)
# For now, leaving it empty; add packages if required (e.g., for cross-compilation or rperf)
RUN apt-get update && apt-get install -y \
    && rm -rf /var/lib/apt/lists/*

# Add the x86_64-unknown-linux-gnu target for cross-compilation
RUN rustup target add x86_64-unknown-linux-gnu

# Fetch and build the latest rperf crate from crates.io
RUN cargo install --target x86_64-unknown-linux-gnu --root /usr/local rperf

# Runtime stage (optional, not needed for .deb but included for completeness)
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/rperf /usr/local/bin/serviceradar-rperf

CMD ["/usr/local/bin/serviceradar-rperf"]