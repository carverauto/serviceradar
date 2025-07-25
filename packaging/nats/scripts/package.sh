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

# package.sh for serviceradar-nats component - Prepares files for Debian packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.12}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p serviceradar-nats-build
cd serviceradar-nats-build

# Create package directory structure (Debian paths)
mkdir -p DEBIAN
mkdir -p lib/systemd/system
mkdir -p etc/nats
mkdir -p etc/nats/templates

echo "Preparing ServiceRadar NATS package files..."

# Copy control file
CONTROL_SRC="${PACKAGING_DIR}/nats/DEBIAN/control"
if [ -f "$CONTROL_SRC" ]; then
    cp "$CONTROL_SRC" DEBIAN/control
    echo "Copied control file from $CONTROL_SRC"
else
    echo "Error: control file not found at $CONTROL_SRC"
    exit 1
fi

# Copy conffiles
CONFFILES_SRC="${PACKAGING_DIR}/nats/DEBIAN/conffiles"
if [ -f "$CONFFILES_SRC" ]; then
    cp "$CONFFILES_SRC" DEBIAN/conffiles
    echo "Copied conffiles from $CONFFILES_SRC"
else
    echo "Error: conffiles not found at $CONFFILES_SRC"
    exit 1
fi

# Copy systemd service file
SERVICE_SRC="${PACKAGING_DIR}/nats/systemd/serviceradar-nats.service"
if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" lib/systemd/system/serviceradar-nats.service
    echo "Copied serviceradar-nats.service from $SERVICE_SRC"
else
    echo "Error: serviceradar-nats.service not found at $SERVICE_SRC"
    exit 1
fi

# Copy NATS config templates instead of a single default config
echo "Copying NATS configuration templates..."
CONFIG_DIR="${PACKAGING_DIR}/nats/config"
cp "${CONFIG_DIR}/nats-standalone.conf" etc/nats/templates/
cp "${CONFIG_DIR}/nats-cloud.conf" etc/nats/templates/
cp "${CONFIG_DIR}/nats-edge-leaf.conf" etc/nats/templates/

# Copy default config file (only if it doesn't exist on the target system)
CONFIG_SRC="${PACKAGING_DIR}/nats/config/nats-server.conf"
if [ ! -f "/etc/nats/nats-server.conf" ] && [ -f "$CONFIG_SRC" ]; then
    cp "$CONFIG_SRC" etc/nats/nats-server.conf
    echo "Copied nats-server.conf from $CONFIG_SRC"
elif [ ! -f "$CONFIG_SRC" ]; then
    echo "Error: nats-server.conf not found at $CONFIG_SRC"
    exit 1
fi

# Copy postinst script
POSTINST_SRC="${PACKAGING_DIR}/nats/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    cp "$POSTINST_SRC" DEBIAN/postinst
    chmod 755 DEBIAN/postinst
    echo "Copied postinst from $POSTINST_SRC"
else
    echo "Error: postinstall.sh not found at $POSTINST_SRC"
    exit 1
fi

# Copy prerm script
PRERM_SRC="${PACKAGING_DIR}/nats/scripts/preremove.sh"
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
dpkg-deb --root-owner-group --build . "serviceradar-nats${VERSION}.deb"

# Move the deb file to the release-artifacts directory
mv "serviceradar-nats${VERSION}.deb" "${BASE_DIR}/release-artifacts/"

echo "Package built: ${BASE_DIR}/release-artifacts/serviceradar-nats${VERSION}.deb"