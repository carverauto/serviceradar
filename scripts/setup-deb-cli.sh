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

# setup-deb-cli.sh - Build serviceradar-cli Debian package
set -e  # Exit on any error

# Ensure we're in the project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
echo "Working directory: $(pwd)"

VERSION=${VERSION:-1.0.31}
VERSION=$(echo "$VERSION" | sed 's/refs\/tags\/v//')  # Clean Git ref if present

echo "Building serviceradar-cli version ${VERSION}"

echo "Setting up package structure..."

# Use a relative path from the script's location
BASE_DIR="$(pwd)"
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create package directory structure
PKG_ROOT="serviceradar-cli_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"

echo "Building Go binary..."

# Build cli binary
cd "${BASE_DIR}/cmd/cli"
GOOS=linux GOARCH=amd64 go build -o "${BASE_DIR}/${PKG_ROOT}/usr/local/bin/serviceradar"
cd "${BASE_DIR}"

echo "Copying package files from filesystem..."

# Copy control file
CONTROL_SRC="${PACKAGING_DIR}/cli/DEBIAN/control"
if [ -f "$CONTROL_SRC" ]; then
    cp "$CONTROL_SRC" "${PKG_ROOT}/DEBIAN/control"
    # Update version in control file (compatible with BSD and GNU sed)
    if ! sed -i.bak "s/^Version:.*$/Version: ${VERSION}/" "${PKG_ROOT}/DEBIAN/control"; then
        echo "Error: Failed to update version in control file"
        exit 1
    fi
    rm -f "${PKG_ROOT}/DEBIAN/control.bak"  # Remove backup file
    echo "Copied and updated control file from $CONTROL_SRC"
else
    echo "Error: control file not found at $CONTROL_SRC"
    exit 1
fi

# Copy conffiles
CONFFILES_SRC="${PACKAGING_DIR}/cli/DEBIAN/conffiles"
if [ -f "$CONFFILES_SRC" ]; then
    cp "$CONFFILES_SRC" "${PKG_ROOT}/DEBIAN/conffiles"
    echo "Copied conffiles from $CONFFILES_SRC"
else
    echo "Error: conffiles not found at $CONFFILES_SRC"
    exit 1
fi

# Copy postinst script
POSTINST_SRC="${PACKAGING_DIR}/poller/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    cp "$POSTINST_SRC" "${PKG_ROOT}/DEBIAN/postinst"
    chmod 755 "${PKG_ROOT}/DEBIAN/postinst"
    echo "Copied postinst from $POSTINST_SRC"
else
    echo "Error: postinstall.sh not found at $POSTINST_SRC"
    exit 1
fi

# Copy prerm script
PRERM_SRC="${PACKAGING_DIR}/poller/scripts/preremove.sh"
if [ -f "$PRERM_SRC" ]; then
    cp "$PRERM_SRC" "${PKG_ROOT}/DEBIAN/prerm"
    chmod 755 "${PKG_ROOT}/DEBIAN/prerm"
    echo "Copied prerm from $PRERM_SRC"
else
    echo "Error: preremove.sh not found at $PRERM_SRC"
    exit 1
fi

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p "${BASE_DIR}/release-artifacts"

# Build the package
dpkg-deb --root-owner-group --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "${BASE_DIR}/release-artifacts/"

echo "Package built: ${BASE_DIR}/release-artifacts/${PKG_ROOT}.deb"