# Build stage
FROM rustlang/rust:nightly AS builder

WORKDIR /usr/src/serviceradar

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY rust ./rust
RUN cargo fetch --locked --manifest-path rust/bmp-collector/Cargo.toml

RUN cargo build \
        --manifest-path rust/bmp-collector/Cargo.toml \
        --locked \
        --release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /output /var/lib/serviceradar /var/log/serviceradar

COPY --from=builder /usr/src/serviceradar/target/release/serviceradar-bmp-collector /usr/local/bin/serviceradar-bmp-collector
COPY --from=builder /usr/src/serviceradar/target/release/serviceradar-bmp-collector /output/serviceradar-bmp-collector

WORKDIR /etc/serviceradar
COPY rust/bmp-collector/bmp-collector.json /etc/serviceradar/bmp-collector.json

RUN groupadd -r -g 1001 serviceradar && useradd -r -u 1001 -g serviceradar serviceradar && \
    chown -R serviceradar:serviceradar /etc/serviceradar /var/lib/serviceradar /var/log/serviceradar

USER serviceradar

EXPOSE 4000/tcp

ENTRYPOINT ["/usr/local/bin/serviceradar-bmp-collector"]
CMD ["--config", "/etc/serviceradar/bmp-collector.json"]
