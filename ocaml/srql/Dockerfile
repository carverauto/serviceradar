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

# Upgrade to opam 2.4.1 (statically linked binary)
RUN curl -fsSL https://github.com/ocaml/opam/releases/download/2.4.1/opam-2.4.1-x86_64-linux \
        -o /usr/local/bin/opam \
    && chmod +x /usr/local/bin/opam \
    && opam --version

USER opam
ENV OPAMYES=1 \
    OPAMCONFIRMLEVEL=unsafe-yes

COPY --chown=opam:opam proton-ocaml-driver /tmp/proton-ocaml-driver

# Refresh repositories, apply local pins, and remove conflicting packages
RUN opam update \
    && git -C /home/opam/opam-repository fetch --depth=1 origin master \
    && git -C /home/opam/opam-repository reset --hard origin/master \
    && opam update \
    && opam pin add proton /tmp/proton-ocaml-driver -y \
    && opam remove -y mirage-crypto mirage-crypto-rng mirage-crypto-rng-lwt tls tls-lwt x509 || true

# Install all dependencies (dream pulls in the mirage-crypto 1.2.x stack)
RUN eval $(opam env) \
    && opam install -y \
        dune \
        menhir \
        yojson \
        ppx_deriving \
        lwt \
        lwt_ppx \
        dream.1.0.0~alpha7 \
        proton \
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
