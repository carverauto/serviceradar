# Build stage
FROM --platform=linux/amd64 rust:latest AS builder

WORKDIR /usr/src/rperf

# Install RPM build tools
RUN apt-get update && apt-get install -y \
    rpm \
    && rm -rf /var/lib/apt/lists/*

# Add the x86_64-unknown-linux-gnu target
RUN rustup target add x86_64-unknown-linux-gnu

# Install rperf
RUN cargo install --target x86_64-unknown-linux-gnu --root /usr/local rperf && \
    ls -l /usr/local/bin/rperf

# Set up RPM build environment
WORKDIR /root/rpmbuild
RUN mkdir -p BUILD RPMS SRPMS SOURCES SPECS BUILDROOT /output
COPY packaging/specs/serviceradar-rperf.spec SPECS/
COPY packaging/rperf/systemd/serviceradar-rperf.service SOURCES/rperf/systemd/

# Build the RPM
ARG VERSION=0.1.18  # Matches rperf version installed
ARG RELEASE=1
RUN cp /usr/local/bin/rperf BUILD/serviceradar-rperf && \
    sed -i "s/%{version}/${VERSION}/g" SPECS/serviceradar-rperf.spec && \
    sed -i "s/%{release}/${RELEASE}/g" SPECS/serviceradar-rperf.spec && \
    rpmbuild -bb SPECS/serviceradar-rperf.spec && \
    find RPMS -type f -name "*.rpm" -exec cp {} /output/ \; && \
    ls -la /output/

# Final stage
FROM --platform=linux/amd64 debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /rpms
COPY --from=builder /output/*.rpm ./
COPY --from=builder /usr/local/bin/rperf /usr/local/bin/serviceradar-rperf

# Verify contents
RUN ls -la /rpms/ || { echo "No RPMs in /rpms/"; exit 1; }

CMD ["/usr/local/bin/serviceradar-rperf"]