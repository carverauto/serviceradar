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

# package.sh for serviceradar-proton component - Prepares files for Debian packaging
set -e

# Enable debugging
set -x

# Define package version
VERSION=${VERSION:-1.0.34}
PROTON_VERSION="v1.6.16"
PROTON_DOWNLOAD_URL="https://github.com/timeplus-io/proton/releases/download/${PROTON_VERSION}/proton-${PROTON_VERSION}-Linux-x86_64"

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using BASE_DIR: $BASE_DIR"
echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Verify PACKAGING_DIR exists
if [ ! -d "$PACKAGING_DIR" ]; then
    echo "Error: PACKAGING_DIR $PACKAGING_DIR does not exist"
    exit 1
fi

# Create the build directory
mkdir -p serviceradar-proton-build
cd serviceradar-proton-build

# Create package directory structure (Debian paths)
mkdir -p DEBIAN
mkdir -p usr/bin
mkdir -p usr/share/serviceradar-proton
mkdir -p lib/systemd/system
mkdir -p var/lib/proton/{tmp,checkpoint,nativelog/meta,nativelog/log,user_files}
mkdir -p var/log/proton-server

# Set permissions on usr/share/serviceradar-proton
chmod 755 usr/share/serviceradar-proton

echo "Downloading Proton binary..."

# Download Proton binary - directly as executable, not as an archive
curl -L -o usr/bin/proton "$PROTON_DOWNLOAD_URL" || { echo "Error: Failed to download Proton binary"; exit 1; }
chmod 755 usr/bin/proton || { echo "Error: Failed to set permissions on Proton binary"; exit 1; }

# Verify the binary is executable
file usr/bin/proton || { echo "Error: Failed to verify Proton binary"; exit 1; }
echo "Proton binary download completed successfully"

echo "Preparing ServiceRadar Proton package files..."

# Copy control file
CONTROL_SRC="${PACKAGING_DIR}/proton/DEBIAN/control"
if [ -f "$CONTROL_SRC" ]; then
    cp "$CONTROL_SRC" DEBIAN/control
    echo "Copied control file from $CONTROL_SRC"
else
    echo "Creating default control file"
    cat > DEBIAN/control << EOF
Package: serviceradar-proton
Version: ${VERSION}
Section: database
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman@carverauto.dev>
Description: ServiceRadar Proton Server (Time-series database)
EOF
fi
chmod 644 DEBIAN/control

# Create conffiles
cat > DEBIAN/conffiles << EOF
/etc/proton-server/config.yaml
/etc/proton-server/users.yaml
/etc/proton-server/grok-patterns
EOF
chmod 644 DEBIAN/conffiles
echo "Created conffiles"

# Copy systemd service file
SERVICE_SRC="${PACKAGING_DIR}/proton/systemd/serviceradar-proton.service"
if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" lib/systemd/system/serviceradar-proton.service
    chmod 644 lib/systemd/system/serviceradar-proton.service
    echo "Copied serviceradar-proton.service from $SERVICE_SRC"
else
    echo "Error: serviceradar-proton.service not found at $SERVICE_SRC"
    exit 1
fi

# Copy config files to usr/share/serviceradar-proton
CONFIG_SRC="${PACKAGING_DIR}/proton/config/config.yaml"
if [ -f "$CONFIG_SRC" ]; then
    cp "$CONFIG_SRC" usr/share/serviceradar-proton/config.yaml
    chmod 644 usr/share/serviceradar-proton/config.yaml
    echo "Copied config.yaml from $CONFIG_SRC"
    ls -l usr/share/serviceradar-proton/config.yaml
else
    echo "Error: config.yaml not found at $CONFIG_SRC"
    exit 1
fi

USERS_SRC="${PACKAGING_DIR}/proton/config/users.yaml"
if [ -f "$USERS_SRC" ]; then
    cp "$USERS_SRC" usr/share/serviceradar-proton/users.yaml
    chmod 644 usr/share/serviceradar-proton/users.yaml
    echo "Copied users.yaml from $USERS_SRC"
    ls -l usr/share/serviceradar-proton/users.yaml
else
    echo "Error: users.yaml not found at $USERS_SRC"
    exit 1
fi

# Copy grok patterns file
GROK_SRC="${PACKAGING_DIR}/proton/config/grok-patterns"
if [ -f "$GROK_SRC" ]; then
    cp "$GROK_SRC" usr/share/serviceradar-proton/grok-patterns
    chmod 644 usr/share/serviceradar-proton/grok-patterns
    echo "Copied grok-patterns from $GROK_SRC"
else
    echo "Warning: grok-patterns not found at $GROK_SRC, creating empty file"
    touch usr/share/serviceradar-proton/grok-patterns
    chmod 644 usr/share/serviceradar-proton/grok-patterns
fi

# Copy postinst script
POSTINST_SRC="${PACKAGING_DIR}/proton/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    cp "$POSTINST_SRC" DEBIAN/postinst
    chmod 755 DEBIAN/postinst
    echo "Copied postinst from $POSTINST_SRC"
else
    echo "Error: postinstall.sh not found at $POSTINST_SRC"
    exit 1
fi

# Copy prerm script
PRERM_SRC="${PACKAGING_DIR}/proton/scripts/preremove.sh"
if [ -f "$PRERM_SRC" ]; then
    cp "$PRERM_SRC" DEBIAN/prerm
    chmod 755 DEBIAN/prerm
    echo "Copied prerm from $PRERM_SRC"
else
    echo "Error: preremove.sh not found at $PRERM_SRC"
    exit 1
fi

# Create a manifest file for debugging
echo "Creating package manifest..."
find . -type f > package_manifest.txt
cat package_manifest.txt

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p "${BASE_DIR}/release-artifacts"

# List out files before building to verify
echo "Files in usr/share/serviceradar-proton:"
ls -la usr/share/serviceradar-proton/

# Build the package
dpkg-deb --root-owner-group --build . "serviceradar-proton_${VERSION}.deb" || { echo "Error: dpkg-deb failed"; exit 1; }

# Verify package contents
echo "Verifying package contents..."
dpkg-deb -c "serviceradar-proton_${VERSION}.deb" > package_contents.txt
cat package_contents.txt
if ! grep -q "usr/share/serviceradar-proton/config.yaml" package_contents.txt; then
    echo "Error: config.yaml not found in package"
    exit 1
fi

# Move the deb file to the release-artifacts directory
mv "serviceradar-proton_${VERSION}.deb" "${BASE_DIR}/release-artifacts/"

echo "Package built: ${BASE_DIR}/release-artifacts/serviceradar-proton_${VERSION}.deb"