#!/bin/bash
set -e

export VERSION=${VERSION}

# Build the builder image
docker build -t serviceradar-builder -f ./Dockerfile.build .

# Run just the cloud package build in the container
docker run --rm -v $(pwd):/build serviceradar-builder ./scripts/setup-deb-cloud.sh

echo "Build completed. Check release-artifacts/ directory for the cloud package."