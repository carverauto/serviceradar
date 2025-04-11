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

# setup-deb-nats.sh - Build the serviceradar-nats Debian package
set -e  # Exit on any error

echo "Setting up package structure for serviceradar-nats..."

VERSION=${VERSION:-1.0.31}
NATS_VERSION=${NATS_VERSION:-2.11.0}  # Default NATS Server version

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create package directory structure
PKG_ROOT="serviceradar-nats_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/bin"
mkdir -p "${PKG_ROOT}/etc/nats"
mkdir -p "${PKG_ROOT}/lib/systemd/system"
mkdir -p "${PKG_ROOT}/var/lib/nats/jetstream"
mkdir -p "${PKG_ROOT}/var/log/nats"

echo "Preparing NATS Server binary..."

# Check if NATS binary exists locally, otherwise download it
if [ ! -f "nats-server-v${NATS_VERSION}-linux-amd64/nats-server" ]; then
    echo "Downloading NATS Server v${NATS_VERSION}..."
    curl -LO "https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/nats-server-v${NATS_VERSION}-linux-amd64.tar.gz"
    tar -xzf "nats-server-v${NATS_VERSION}-linux-amd64.tar.gz"
fi
cp "nats-server-v${NATS_VERSION}-linux-amd64/nats-server" "${PKG_ROOT}/usr/bin/"

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-nats
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman@carverauto.dev>
Description: ServiceRadar NATS JetStream service
 Provides NATS JetStream server configured for ServiceRadar KV store functionality.
Config: /etc/nats/nats-server.conf
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/nats/nats-server.conf
EOF

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/nats/systemd/serviceradar-nats.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" "${PKG_ROOT}/lib/systemd/system/serviceradar-nats.service"
    echo "Copied serviceradar-nats.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-nats.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy nats-server.conf from the filesystem
NATS_CONF_SRC="${PACKAGING_DIR}/nats/config/nats-server.conf"
if [ -f "$NATS_CONF_SRC" ]; then
    cp "$NATS_CONF_SRC" "${PKG_ROOT}/etc/nats/nats-server.conf"
    echo "Copied nats-server.conf from $NATS_CONF_SRC"
else
    echo "Error: nats-server.conf not found at $NATS_CONF_SRC"
    exit 1
fi

# Create postinst script
cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Create nats user and group if they don't exist
if ! getent group nats >/dev/null; then
    groupadd --system nats
fi
if ! id -u nats >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid nats nats
fi

# Create required directories
mkdir -p /var/lib/nats/jetstream /var/log/nats

# Set permissions
chown -R nats:nats /etc/nats /var/lib/nats /var/log/nats
chmod 755 /usr/bin/nats-server
chmod 644 /etc/nats/nats-server.conf
chmod -R 750 /var/lib/nats /var/log/nats
chmod 600 /etc/serviceradar/api.env  # Ensure api.env has restrictive permissions
usermod -a -G serviceradar nats
chmod g+x /etc/serviceradar/certs

# Add nats user to serviceradar group if it exists
if getent group serviceradar >/dev/null; then
    usermod -aG serviceradar nats
fi
# Allow nats user to read the ServiceRadar certificates if they exist
if [ -d "/etc/serviceradar/certs/" ]; then
    chmod 750 /etc/serviceradar/certs/
fi

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-nats
systemctl start serviceradar-nats || echo "Failed to start service, please check the logs"

echo "ServiceRadar NATS JetStream service installed successfully!"
echo "NATS is running on port 4222 (localhost only)"
exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop serviceradar-nats || true
systemctl disable serviceradar-nats || true

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