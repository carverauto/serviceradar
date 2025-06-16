FROM rust:1.38 AS builder

WORKDIR /flowgger
COPY . .

RUN apt-get update && \
	apt-get install -y capnproto && \
    cargo build --release && \
    strip target/release/flowgger


FROM debian:buster-slim
LABEL maintainer="Frank Denis, Damian Czaja <trojan295@gmail.com>"

WORKDIR /opt/flowgger

RUN apt-get update && \
	apt-get install -y libssl1.1 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /flowgger/target/release/flowgger /opt/flowgger/bin/flowgger
COPY flowgger.toml /opt/flowgger/etc/flowgger.toml
COPY docker/entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/opt/flowgger/etc/flowgger.toml"]
