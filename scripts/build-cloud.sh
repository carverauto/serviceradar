#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
  VERSION="dev"
fi

echo "Building cloud component version ${VERSION}"

# Ensure output directory exists
mkdir -p ../dist/cloud_linux_amd64_v1

# Build using Docker
docker build -f ../Dockerfile.cloud \
  --build-arg VERSION="${VERSION}" \
  -t serviceradar-cloud-build:${VERSION} ../.

# Extract binary
CONTAINER_ID=$(docker create serviceradar-cloud-build:${VERSION})
docker cp ${CONTAINER_ID}:/src/serviceradar-cloud dist/cloud_linux_amd64_v1/
docker rm ${CONTAINER_ID}

echo "Cloud build complete"