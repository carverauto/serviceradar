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

# package.sh for serviceradar-device-mgr component - Prepares files for Debian packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.32}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p serviceradar-device-mgr-build
cd serviceradar-device-mgr-build

# Create package directory structure (Debian paths)
mkdir -p DEBIAN
mkdir -p usr/local/bin
mkdir -p etc/serviceradar/
mkdir -p lib/systemd/system

echo "Building device mgr binary..."

# Build Go binary
cd "${BASE_DIR}/cmd/consumers/device"
GOOS=linux GOARCH=amd64 go build -o "../../../serviceradar-device-mgr-build/usr/local/bin/serviceradar-device-mgr"
cd "${BASE_DIR}"

echo "Preparing ServiceRadar device manager package files..."

# Copy control file
CONTROL_SRC="${PACKAGING_DIR}/device-manager/DEBIAN/control"
if [ -f "$CONTROL_SRC" ]; then
    cp "$CONTROL_SRC" DEBIAN/control
    echo "Copied control file from $CONTROL_SRC"
else
    echo "Error: control file not found at $CONTROL_SRC"
    exit 1
fi

# Copy conffiles
CONFFILES_SRC="${PACKAGING_DIR}/device-manager/DEBIAN/conffiles"
if [ -f "$CONFFILES_SRC" ]; then
    cp "$CONFFILES_SRC" DEBIAN/conffiles
    echo "Copied conffiles from $CONFFILES_SRC"
else
    echo "Error: conffiles not found at $CONFFILES_SRC"
    exit 1
fi

# Copy systemd service file
SERVICE_SRC="${PACKAGING_DIR}/device-mgr/systemd/serviceradar-device-mgr.service"
if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" lib/systemd/system/serviceradar-device-mgr.service
    echo "Copied serviceradar-device-mgr.service from $SERVICE_SRC"
else
    echo "Error: serviceradar-device-mgr.service not found at $SERVICE_SRC"
    exit 1
fi

# Copy default config file (only if it doesn't exist on the target system)
CONFIG_SRC="${PACKAGING_DIR}/device-mgr/config/devices.json"
if [ ! -f "/etc/serviceradar/devices.json" ] && [ -f "$CONFIG_SRC" ]; then
    cp "$CONFIG_SRC" etc/serviceradar/devices.json
    echo "Copied devices.json from $CONFIG_SRC"
elif [ ! -f "$CONFIG_SRC" ]; then
    echo "Error: devices.json not found at $CONFIG_SRC"
    exit 1
fi

# Copy postinst script
POSTINST_SRC="${PACKAGING_DIR}/device-manager/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    cp "$POSTINST_SRC" DEBIAN/postinst
    chmod 755 DEBIAN/postinst
    echo "Copied postinst from $POSTINST_SRC"
else
    echo "Error: postinstall.sh not found at $POSTINST_SRC"
    exit 1
fi

# Copy prerm script
PRERM_SRC="${PACKAGING_DIR}/device-manager/scripts/preremove.sh"
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
dpkg-deb --root-owner-group --build . "serviceradar-device-mgr_${VERSION}.deb"

# Move the deb file to the release-artifacts directory
mv "serviceradar-device-mgr_${VERSION}.deb" "${BASE_DIR}/release-artifacts/"

echo "Package built: ${BASE_DIR}/release-artifacts/serviceradar-device-mgr_${VERSION}.deb"