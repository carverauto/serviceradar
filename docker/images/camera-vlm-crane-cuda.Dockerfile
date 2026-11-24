# syntax=docker/dockerfile:1.7
# Standalone linux/arm64 CUDA build of crane-serve (lucasjinreal/Crane, MIT) for
# local Docker builds. CI publishes serviceradar-camera-vlm-cuda via the split
# native workflow (.github/workflows/publish-camera-vlm-cuda.yml) using the same
# pinned CUDA 13.0.3 devel image, Rust 1.98.0 toolchain, Crane commit, and
# compute capability (12.1 / GB10).

ARG CUDA_DEVEL_IMAGE=docker.io/nvidia/cuda@sha256:b7ae301dea2c162444795462ce17a05f6a516e5a75944b57af5b88540a1a2266
ARG RUNTIME_BASE_IMAGE=registry.carverauto.dev/mirror/library/ubuntu@sha256:d1e2e92c075e5ca139d51a140fff46f84315c0fdce203eab2807c7e495eff4f9
ARG RUST_VERSION=1.98.0
ARG CRANE_COMMIT=55835189af0848a180e6ed70313d59272e7c92a1
ARG CRANE_TARBALL_SHA256=07a2abbdff4cb78c5e7bf9da535213121417f99cd5afe064d5e53c3e3c75288b
ARG CUDA_COMPUTE_CAP=121

FROM --platform=linux/arm64 ${CUDA_DEVEL_IMAGE} AS builder

ARG RUST_VERSION
ARG CRANE_COMMIT
ARG CRANE_TARBALL_SHA256
ARG CUDA_COMPUTE_CAP

ENV DEBIAN_FRONTEND=noninteractive \
    CUDA_COMPUTE_CAP=${CUDA_COMPUTE_CAP} \
    CARGO_HOME=/opt/cargo \
    RUSTUP_HOME=/opt/rustup \
    PATH=/opt/cargo/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
    && rm -rf /var/lib/apt/lists/* \
    && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}"

WORKDIR /build

RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
      -o crane.tar.gz "https://github.com/lucasjinreal/Crane/archive/${CRANE_COMMIT}.tar.gz" \
    && echo "${CRANE_TARBALL_SHA256}  crane.tar.gz" | sha256sum -c - \
    && tar -xzf crane.tar.gz \
    && rm crane.tar.gz

WORKDIR /build/Crane-${CRANE_COMMIT}

RUN cargo build --release -p crane-serve --features cuda --bin crane-serve \
    && install -m 0755 target/release/crane-serve /out/crane-serve \
    && mkdir -p /out/lib /out/third-party \
    && for lib in \
         libcublas.so.13 \
         libcublasLt.so.13 \
         libcurand.so.10 \
         libnvrtc.so.13 \
         libnvrtc-builtins.so.13.0 \
         libcudart.so.13; do \
         cp -L "/usr/local/cuda/lib64/${lib}" "/out/lib/${lib}"; \
         chmod 0644 "/out/lib/${lib}"; \
       done \
    && for pkg in libcublas-13-0 libcurand-13-0 cuda-nvrtc-13-0 cuda-cudart-13-0; do \
         install -m 0644 "/usr/share/doc/${pkg}/copyright" "/out/third-party/${pkg}.copyright"; \
       done \
    && install -m 0644 LICENSE /out/third-party/crane.LICENSE

FROM --platform=linux/arm64 ${RUNTIME_BASE_IMAGE} AS runtime

ARG CRANE_COMMIT

LABEL org.opencontainers.image.title="serviceradar-camera-vlm-cuda" \
      org.opencontainers.image.source="https://github.com/carverauto/serviceradar" \
      io.serviceradar.crane.commit="${CRANE_COMMIT}"

RUN groupadd --gid 10001 serviceradar \
    && useradd --uid 10001 --gid 10001 --create-home --home-dir /home/serviceradar --shell /bin/sh serviceradar \
    && mkdir -p /models /var/lib/serviceradar /var/log/serviceradar /var/cache/serviceradar-camera-vlm/cuda \
    && chown -R 10001:10001 /home/serviceradar /var/lib/serviceradar /var/cache/serviceradar-camera-vlm/cuda

COPY --from=builder /out/crane-serve /usr/local/bin/crane-serve
COPY --from=builder /out/lib/ /usr/local/lib/serviceradar-cuda/
COPY --from=builder /out/third-party/ /usr/share/doc/serviceradar-camera-vlm-cuda/third-party/

ENV LD_LIBRARY_PATH=/usr/local/lib/serviceradar-cuda \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    HOME=/home/serviceradar \
    CUDA_CACHE_PATH=/var/cache/serviceradar-camera-vlm/cuda \
    CUDA_CACHE_MAXSIZE=1073741824 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

WORKDIR /var/lib/serviceradar
USER 10001:10001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/crane-serve"]
