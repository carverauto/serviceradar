#!/bin/bash
# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# setup-deb-core.sh - Build serviceradar-core Debian package in a Docker container
set -e

# Ensure we're in the project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
echo "Working directory: $(pwd)"

VERSION=${VERSION:-1.0.30}
VERSION=$(echo "$VERSION" | sed 's/refs\/tags\/v//')  # Clean Git ref if present
BUILD_TAGS=${BUILD_TAGS:-""}

echo "VERSION: $VERSION"
echo "BUILD_TAGS: $BUILD_TAGS"

# Define Docker image name
IMAGE_NAME="serviceradar-core-builder:${VERSION}"

# Build the Docker image
echo "Building Docker image $IMAGE_NAME..."
docker build \
    --platform linux/amd64 \
    --build-arg VERSION="$VERSION" \
    -f Dockerfile.core \
    -t "$IMAGE_NAME" \
    .

# Verify the image exists
echo "Verifying built image..."
docker images "$IMAGE_NAME" || { echo "Error: Image $IMAGE_NAME not found after build"; exit 1; }

# Run the container to build the Debian package
echo "Running container to build the Debian package..."
docker run \
    --rm \
    --platform linux/amd64 \
    -v "$(pwd)/release-artifacts:/output" \
    -e VERSION="$VERSION" \
    "$IMAGE_NAME" \
    bash -c "\
        set -e; \
        echo 'Setting up package structure...'; \
        PKG_ROOT=/tmp/serviceradar-core_\${VERSION}; \
        BASE_DIR=/src; \
        PACKAGING_DIR=\${BASE_DIR}/packaging; \
        mkdir -p \${PKG_ROOT}/DEBIAN; \
        mkdir -p \${PKG_ROOT}/usr/local/bin; \
        mkdir -p \${PKG_ROOT}/etc/serviceradar; \
        mkdir -p \${PKG_ROOT}/lib/systemd/system; \
        [ -d \"\${PKG_ROOT}/DEBIAN\" ] || { echo 'Error: Failed to create directory \${PKG_ROOT}/DEBIAN'; exit 1; }; \
        echo 'Copying Go binary...'; \
        cp /src/serviceradar-core \${PKG_ROOT}/usr/local/bin/serviceradar-core || { echo 'Error: Binary not found at /src/serviceradar-core'; exit 1; }; \
        echo 'Copying package files from filesystem...'; \
        cp \${PACKAGING_DIR}/core/DEBIAN/control \${PKG_ROOT}/DEBIAN/control && sed -i \"s/Version:.*/Version: \${VERSION}/\" \${PKG_ROOT}/DEBIAN/control || { echo 'Error: control file missing'; exit 1; }; \
        cp \${PACKAGING_DIR}/core/DEBIAN/conffiles \${PKG_ROOT}/DEBIAN/conffiles || { echo 'Error: conffiles missing'; exit 1; }; \
        cp \${PACKAGING_DIR}/core/systemd/serviceradar-core.service \${PKG_ROOT}/lib/systemd/system/serviceradar-core.service || { echo 'Error: service file missing'; exit 1; }; \
        cp \${PACKAGING_DIR}/core/config/core.json \${PKG_ROOT}/etc/serviceradar/core.json || { echo 'Error: core.json missing'; exit 1; }; \
        cp \${PACKAGING_DIR}/core/config/checkers/sweep/sweep.json \${PKG_ROOT}/etc/serviceradar/checkers/sweep/sweep.json || { echo 'Error: sweep.json missing'; exit 1; }; \
        [ -f \${PACKAGING_DIR}/core/config/api.env ] && cp \${PACKAGING_DIR}/core/config/api.env \${PKG_ROOT}/etc/serviceradar/api.env && echo 'Copied api.env' || echo 'Note: api.env not found, skipping'; \
        cp \${PACKAGING_DIR}/core/scripts/postinstall.sh \${PKG_ROOT}/DEBIAN/postinst && chmod 755 \${PKG_ROOT}/DEBIAN/postinst || { echo 'Error: postinstall.sh missing'; exit 1; }; \
        cp \${PACKAGING_DIR}/core/scripts/preremove.sh \${PKG_ROOT}/DEBIAN/prerm && chmod 755 \${PKG_ROOT}/DEBIAN/prerm || { echo 'Error: preremove.sh missing'; exit 1; }; \
        echo 'Building Debian package...'; \
        dpkg-deb --root-owner-group --build \${PKG_ROOT}; \
        echo 'Moving package to output...'; \
        mv \${PKG_ROOT}.deb /output/serviceradar-core_\${VERSION}.deb; \
    "

echo "Package built: release-artifacts/serviceradar-core_${VERSION}.deb"