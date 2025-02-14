#!/bin/bash
set -e

export VERSION=${VERSION:-1.0.16}
export RELEASE=${RELEASE:-1}

# Create temporary build directory
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# Build the RPM using multi-stage Docker build
docker build \
    --platform linux/amd64 \
    --build-arg VERSION="${VERSION}" \
    --build-arg RELEASE="${RELEASE}" \
    -f Dockerfile-rpm.cloud \
    -t serviceradar-rpm-builder \
    .

# Extract RPM from the container to temp directory
container_id=$(docker create serviceradar-rpm-builder)
docker cp $container_id:/rpms/. "$tmp_dir/"
docker rm $container_id

# Copy only RPM files to release directory
find "$tmp_dir" -name "*.rpm" -exec cp {} "release-artifacts/${VERSION}/rpm/" \;

echo "Build completed. RPMs are in release-artifacts/${VERSION}/rpm/"