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

# setup-deb-agent.sh
set -e  # Exit on any error

VERSION=${VERSION:-1.0.28}
echo "Building serviceradar-agent version ${VERSION}"

echo "Setting up package structure..."

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create package directory structure
PKG_ROOT="serviceradar-agent_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar/checkers"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binary..."

# Build agent binary
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/serviceradar-agent" "${BASE_DIR}/cmd/agent"

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-agent
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar monitoring agent with Dusk node checker
 This package provides the serviceradar monitoring agent and
 a Dusk node checker plugin for monitoring services.
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/agent.json
/etc/serviceradar/api.env
EOF

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/agent/systemd/serviceradar-agent.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" "${PKG_ROOT}/lib/systemd/system/serviceradar-agent.service"
    echo "Copied serviceradar-agent.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-agent.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy agent.json from the filesystem
AGENT_JSON_SRC="${PACKAGING_DIR}/agent/config/agent.json"
if [ -f "$AGENT_JSON_SRC" ]; then
    cp "$AGENT_JSON_SRC" "${PKG_ROOT}/etc/serviceradar/agent.json"
    echo "Copied agent.json from $AGENT_JSON_SRC"
else
    echo "Error: agent.json not found at $AGENT_JSON_SRC"
    exit 1
fi

# Copy api.env from the filesystem (assuming it’s shared across components)
API_ENV_SRC="${PACKAGING_DIR}/core/config/api.env"
if [ -f "$API_ENV_SRC" ]; then
    cp "$API_ENV_SRC" "${PKG_ROOT}/etc/serviceradar/api.env"
    echo "Copied api.env from $API_ENV_SRC"
else
    echo "Error: api.env not found at $API_ENV_SRC"
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
chmod 755 /usr/local/bin/serviceradar-agent
chmod 600 /etc/serviceradar/api.env  # Ensure api.env has restrictive permissions

# Set required capability for ICMP scanning
if [ -x /usr/local/bin/serviceradar-agent ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent
fi

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-agent
systemctl start serviceradar-agent

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-agent || true
systemctl disable serviceradar-agent || true

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