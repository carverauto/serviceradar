FROM rust:1.69-slim as builder

WORKDIR /usr/src/rperf-grpc

# Copy Cargo.toml and Cargo.lock files
COPY Cargo.toml Cargo.lock* ./

# Copy source code
COPY src ./src/
COPY proto ./proto/
COPY build.rs ./

# Build the application
RUN cargo build --release

# Create a smaller runtime image
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install rperf 
RUN apt-get update && apt-get install -y curl
RUN curl -L https://github.com/mfreeman451/rperf/releases/download/v0.1.9/rperf_0.1.9_amd64.deb -o rperf.deb && \
    dpkg -i rperf.deb && \
    rm rperf.deb

# Copy the binary from the builder stage
COPY --from=builder /usr/src/rperf-grpc/target/release/rperf-grpc /usr/local/bin/rperf-grpc

# Create a directory for the configuration
WORKDIR /etc/rperf-grpc
COPY config.json ./

# Create a non-root user to run the application
RUN groupadd -r rperf && useradd -r -g rperf rperf
RUN chown -R rperf:rperf /etc/rperf-grpc
USER rperf

EXPOSE 50051

# Run the application
CMD ["rperf-grpc", "--config", "/etc/rperf-grpc/config.json"]