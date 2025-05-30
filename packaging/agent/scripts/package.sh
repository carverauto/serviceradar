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

# package.sh for serviceradar-agent component - Prepares files for Debian packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.12}
echo "Building serviceradar-agent version ${VERSION}"

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p serviceradar-agent-build
cd serviceradar-agent-build

# Create package directory structure (Debian paths)
mkdir -p DEBIAN
mkdir -p usr/local/bin
mkdir -p etc/serviceradar/checkers
mkdir -p lib/systemd/system

echo "Building Go binary..."

# Build Go binary
cd "${BASE_DIR}/cmd/agent"
GOOS=linux GOARCH=amd64 go build -o "../../serviceradar-agent-build/usr/local/bin/serviceradar-agent"
cd "${BASE_DIR}"

echo "Preparing ServiceRadar Agent package files..."

# Copy control file
CONTROL_SRC="${PACKAGING_DIR}/agent/DEBIAN/control"
if [ -f "$CONTROL_SRC" ]; then
    cp "$CONTROL_SRC" DEBIAN/control
    echo "Copied control file from $CONTROL_SRC"
else
    echo "Error: control file not found at $CONTROL_SRC"
    exit 1
fi

# Copy conffiles
CONFFILES_SRC="${PACKAGING_DIR}/agent/DEBIAN/conffiles"
if [ -f "$CONFFILES_SRC" ]; then
    cp "$CONFFILES_SRC" DEBIAN/conffiles
    echo "Copied conffiles from $CONFFILES_SRC"
else
    echo "Error: conffiles not found at $CONFFILES_SRC"
    exit 1
fi

# Copy systemd service file
SERVICE_SRC="${PACKAGING_DIR}/agent/systemd/serviceradar-agent.service"
if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" lib/systemd/system/serviceradar-agent.service
    echo "Copied serviceradar-agent.service from $SERVICE_SRC"
else
    echo "Error: serviceradar-agent.service not found at $SERVICE_SRC"
    exit 1
fi

# Copy default config file (only if it doesn't exist on the target system)
CONFIG_SRC="${PACKAGING_DIR}/agent/config/agent.json"
if [ ! -f "/etc/serviceradar/agent.json" ] && [ -f "$CONFIG_SRC" ]; then
    cp "$CONFIG_SRC" etc/serviceradar/agent.json
    echo "Copied agent.json from $CONFIG_SRC"
elif [ ! -f "$CONFIG_SRC" ]; then
    echo "Error: agent.json not found at $CONFIG_SRC"
    exit 1
fi

SWEEP_CONFIG_SRC="${PACKAGING_DIR}/core/config/checkers/sweep/sweep.json"
if [ ! -f "/etc/serviceradar/checkers/sweep/sweep.json" ] && [ -f "$SWEEP_CONFIG_SRC" ]; then
    cp "$SWEEP_CONFIG_SRC" etc/serviceradar/checkers/sweep/sweep.json
    echo "Copied sweep.json from $SWEEP_CONFIG_SRC"
elif [ ! -f "$SWEEP_CONFIG_SRC" ]; then
    echo "Error: sweep.json not found at $SWEEP_CONFIG_SRC"
    exit 1
fi

# Copy postinst script
POSTINST_SRC="${PACKAGING_DIR}/agent/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    cp "$POSTINST_SRC" DEBIAN/postinst
    chmod 755 DEBIAN/postinst
    echo "Copied postinst from $POSTINST_SRC"
else
    echo "Error: postinstall.sh not found at $POSTINST_SRC"
    exit 1
fi

# Copy prerm script
PRERM_SRC="${PACKAGING_DIR}/agent/scripts/preremove.sh"
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
dpkg-deb --root-owner-group --build . "serviceradar-agent_${VERSION}.deb"

# Move the deb file to the release-artifacts directory
mv "serviceradar-agent_${VERSION}.deb" "${BASE_DIR}/release-artifacts/"

echo "Package built: ${BASE_DIR}/release-artifacts/serviceradar-agent_${VERSION}.deb"