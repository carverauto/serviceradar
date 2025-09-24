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

# Update opam to 2.2.1 and refresh repositories
RUN opam update \
    && git -C /home/opam/opam-repository fetch --depth=1 origin master \
    && git -C /home/opam/opam-repository reset --hard origin/master \
    && opam update

# Install all dependencies
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
        h2.0.13.0 \
        h2-lwt.0.13.0 \
        h2-lwt-unix.0.13.0 \
        dream.1.0.0~alpha7 \
        proton.1.0.16 \
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