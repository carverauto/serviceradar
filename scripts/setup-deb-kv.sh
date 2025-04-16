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

# setup-deb-kv.sh
set -e  # Exit on any error

VERSION=${VERSION:-1.0.31}
echo "Building serviceradar-kv version ${VERSION}"

echo "Setting up package structure..."

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create package directory structure
PKG_ROOT="serviceradar-kv_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binary..."

# Build kv binary
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/serviceradar-kv" "${BASE_DIR}/cmd/kv"

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-kv
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman@carverauto.dev>
Description: ServiceRadar Key-Value store
 This package provides the ServiceRadar key-value store service.
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/kv.json
EOF

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/kv/systemd/serviceradar-kv.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" "${PKG_ROOT}/lib/systemd/system/serviceradar-kv.service"
    echo "Copied serviceradar-kv.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-kv.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy kv.json from the filesystem
KV_JSON_SRC="${PACKAGING_DIR}/kv/config/kv.json"
if [ -f "$KV_JSON_SRC" ]; then
    cp "$KV_JSON_SRC" "${PKG_ROOT}/etc/serviceradar/kv.json"
    echo "Copied kv.json from $KV_JSON_SRC"
else
    echo "Error: kv.json not found at $KV_JSON_SRC"
    exit 1
fi

# Create postinst script
cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/serviceradar-kv

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-kv
systemctl start serviceradar-kv

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-kv || true
systemctl disable serviceradar-kv || true

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p ./release-artifacts

# Build the package
dpkg-deb --root-owner-group --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "./release-artifacts/"

echo "Package built: release-artifacts/${PKG_ROOT}.deb"