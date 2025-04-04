# Build stage
FROM --platform=linux/amd64 ghcr.io/carverauto/rockylinux9-rust-rpm-base:latest AS builder

WORKDIR /usr/src/rperf

# Install rperf from crates.io
RUN cargo install --target x86_64-unknown-linux-gnu --root /usr/local rperf && \
    ls -l /usr/local/bin/rperf

# Set up RPM build environment
WORKDIR /root/rpmbuild
RUN mkdir -p BUILD RPMS SRPMS SOURCES SPECS BUILDROOT /output
COPY packaging/specs/serviceradar-rperf.spec SPECS/
COPY packaging/rperf/systemd/serviceradar-rperf.service SOURCES/rperf/systemd/

# Build the RPM
ARG VERSION=1.0.28
ARG RELEASE=1
RUN cp /usr/local/bin/rperf BUILD/serviceradar-rperf && \
    sed -i "s/%{version}/${VERSION}/g" SPECS/serviceradar-rperf.spec && \
    sed -i "s/%{release}/${RELEASE}/g" SPECS/serviceradar-rperf.spec && \
    rpmbuild -bb SPECS/serviceradar-rperf.spec && \
    find RPMS -type f -name "*.rpm" -exec cp {} /output/ \; && \
    ls -la /output/ || { echo "No RPMs found in /output/"; exit 1; }

# Final stage
FROM --platform=linux/amd64 rockylinux:9

WORKDIR /rpms
COPY --from=builder /output/*.rpm ./
COPY --from=builder /usr/local/bin/rperf /usr/local/bin/serviceradar-rperf

# Verify contents
RUN ls -la /rpms/ || { echo "No RPMs in /rpms/"; exit 1; }

CMD ["/usr/local/bin/serviceradar-rperf"]