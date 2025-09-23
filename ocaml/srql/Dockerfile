# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ocaml/opam:ubuntu-24.04-ocaml-5.2
FROM ${BASE_IMAGE} AS builder

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libev-dev \
        libffi-dev \
        libgmp-dev \
        liblz4-dev \
        libssl-dev \
        libzstd-dev \
        pkg-config \
        rsync \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

USER opam
ENV OPAMYES=1 \
    OPAMCONFIRMLEVEL=unsafe-yes

# Install h2 first with the correct version to avoid conflicts
RUN opam update && opam install -y "h2>=0.13.0" "h2-lwt>=0.13.0" "h2-lwt-unix>=0.13.0"

# Update opam repository to get latest packages and install proton 1.0.16
RUN opam update && opam install -y "proton>=1.0.16"

# Clone and modify Dream to work with h2 >= 0.13.0
ARG DREAM_REF="master"
RUN git clone --depth 1 --branch "${DREAM_REF}" https://github.com/aantron/dream.git /tmp/dream \
    && cd /tmp/dream \
    && sed -i 's/"h2" {< "0.13.0"}/"h2" {>= "0.13.0"}/' dream-httpaf.opam \
    && sed -i 's/"h2-lwt-unix" {< "0.13.0"}/"h2-lwt-unix" {>= "0.13.0"}/' dream-httpaf.opam \
    && sed -i 's/"h2-lwt" {< "0.13.0"}/"h2-lwt" {>= "0.13.0"}/' dream-httpaf.opam \
    && opam pin add dream-httpaf /tmp/dream -n \
    && opam pin add dream-pure /tmp/dream -n \
    && opam pin add dream /tmp/dream -n

RUN opam install -y \
        dune \
        menhir \
        yojson \
        ppx_deriving \
        lwt \
        lwt_ppx \
        tls \
        tls-lwt \
        mirage-crypto \
        mirage-crypto-rng \
        mirage-crypto-rng-lwt \
        x509 \
        dream-httpaf \
        dream-pure \
        dream \
    && opam clean -a -c

WORKDIR /src
COPY --chown=opam:opam ocaml/ ./ocaml
WORKDIR /src/ocaml

RUN eval $(opam env) \
    && opam install . --deps-only -y \
    && dune build --profile=release srql/bin/main.exe \
    && install -Dm755 _build/default/srql/bin/main.exe /tmp/serviceradar-srql

FROM debian:12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libev4 \
        libgmp10 \
        liblz4-1 \
        libssl3 \
        libzstd1 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /output
COPY --from=builder /tmp/serviceradar-srql /output/serviceradar-srql

CMD ["/bin/true"]
