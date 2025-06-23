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

# package.sh for serviceradar-goflow2 component - Prepares files for Debian packaging
set -e

# --- Configuration ---
# You can override this with an environment variable: VERSION=1.0.1 ./package.sh
VERSION=${VERSION:-1.0.0}
PACKAGE_NAME="serviceradar-goflow2"
COMPONENT_NAME="goflow2"
REPO_URL="https://github.com/mfreeman451/goflow2.git"
# IMPORTANT: For reproducible builds, replace 'main' with a specific commit hash.
REPO_REF="main"

# --- Script Logic ---
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" # Assumes script is in packaging/goflow2/scripts
PACKAGING_DIR="${BASE_DIR}/packaging/${COMPONENT_NAME}"
BUILD_DIR="${BASE_DIR}/${PACKAGE_NAME}-build"

echo "Using PACKAGING_DIR: ${PACKAGING_DIR}"
echo "Using BUILD_DIR: ${BUILD_DIR}"

# Clean up previous build and create the directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Create package directory structure (Debian paths)
mkdir -p DEBIAN
mkdir -p usr/local/bin
mkdir -p etc/serviceradar/
mkdir -p lib/systemd/system

echo "Cloning and building goflow2 binary from external repository..."

# Clone the repository into a temporary source directory
git clone "${REPO_URL}" "goflow2-src"
cd "goflow2-src"
git checkout "${REPO_REF}"

# Build the Go binary, placing the output directly into the build structure
# The `cd` is critical to ensure Go builds it as a separate module.
GOOS=linux GOARCH=amd64 go build -o "../usr/local/bin/${COMPONENT_NAME}" ./cmd/goflow2

# Return to the main build directory
cd ..

echo "Preparing ServiceRadar goflow2 package files..."

# Copy control file
CONTROL_SRC="${PACKAGING_DIR}/DEBIAN/control"
if [ -f "$CONTROL_SRC" ]; then
    # Replace the version placeholder in the control file
    sed "s/{{VERSION}}/${VERSION}/g" "$CONTROL_SRC" > DEBIAN/control
    echo "Copied and processed control file from $CONTROL_SRC"
else
    echo "Error: control file not found at $CONTROL_SRC"
    exit 1
fi

# Copy systemd service file
SERVICE_SRC="${PACKAGING_DIR}/systemd/${PACKAGE_NAME}.service"
if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" "lib/systemd/system/${PACKAGE_NAME}.service"
    echo "Copied ${PACKAGE_NAME}.service from $SERVICE_SRC"
else
    echo "Error: ${PACKAGE_NAME}.service not found at $SERVICE_SRC"
    exit 1
fi

# Copy default config file (optional, as it might be created by the user)
CONFIG_SRC="${PACKAGING_DIR}/config/goflow2.conf"
if [ -f "$CONFIG_SRC" ]; then
    cp "$CONFIG_SRC" "etc/serviceradar/goflow2.conf"
    echo "Copied default config from $CONFIG_SRC."
fi

# Copy conffiles (if any)
CONFFILES_SRC="${PACKAGING_DIR}/DEBIAN/conffiles"
if [ -f "$CONFFILES_SRC" ]; then
    cp "$CONFFILES_SRC" DEBIAN/conffiles
    echo "Copied conffiles from $CONFFILES_SRC"
fi

# Copy postinst script
POSTINST_SRC="${PACKAGING_DIR}/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    cp "$POSTINST_SRC" DEBIAN/postinst
    chmod 755 DEBIAN/postinst
    echo "Copied postinst from $POSTINST_SRC"
else
    echo "Error: postinstall.sh not found at $POSTINST_SRC"
    exit 1
fi

# Copy prerm script
PRERM_SRC="${PACKAGING_DIR}/scripts/preremove.sh"
if [ -f "$PRERM_SRC" ]; then
    cp "$PRERM_SRC" DEBIAN/prerm
    chmod 755 DEBIAN/prerm
    echo "Copied prerm from $PRERM_SRC"
else
    echo "Error: preremove.sh not found at $PRERM_SRC"
    exit 1
fi

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p "${BASE_DIR}/release-artifacts"

# Build the package
dpkg-deb --root-owner-group --build . "${PACKAGE_NAME}_${VERSION}.deb"

# Move the deb file to the release-artifacts directory
mv "${PACKAGE_NAME}_${VERSION}.deb" "${BASE_DIR}/release-artifacts/"

# Clean up the build directory
cd "${BASE_DIR}"
rm -rf "${BUILD_DIR}"

echo "Package built: ${BASE_DIR}/release-artifacts/${PACKAGE_NAME}_${VERSION}.deb"