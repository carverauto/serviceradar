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

# setup-deb-agent.sh - Build the serviceradar-agent Debian package
set -e  # Exit on any error

# Use absolute paths to avoid any directory issues
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"  # Go up one level from scripts/ to root
cd "${BASE_DIR}"  # Change to base directory to ensure all paths work correctly

echo "Working directory: $(pwd)"

# Define version
VERSION=${VERSION:-1.0.31}
echo "Building serviceradar-agent version ${VERSION}"

# Set up packaging directory path
PACKAGING_DIR="${BASE_DIR}/packaging"
echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Output some debug info
echo "Directory structure check:"
ls -la "${PACKAGING_DIR}/agent/DEBIAN" || echo "DEBIAN directory not found"

# Create package directory structure
PKG_ROOT="${BASE_DIR}/serviceradar-agent_${VERSION}"
echo "Creating package in: ${PKG_ROOT}"

# Remove previous build if it exists
rm -rf "${PKG_ROOT}"

# Create necessary directories
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar/checkers/sweep"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

# Debug check - make sure the directory was created
if [ ! -d "${PKG_ROOT}/DEBIAN" ]; then
    echo "Error: Failed to create directory ${PKG_ROOT}/DEBIAN"
    echo "Current directory: $(pwd)"
    echo "Directory listing:"
    ls -la
    exit 1
fi

echo "Building Go binary..."
# Build the agent binary (you may need to adjust the path depending on your Go project structure)
GO_SRC_DIR="${BASE_DIR}/cmd/agent"
if [ -d "$GO_SRC_DIR" ]; then
    cd "$GO_SRC_DIR"
    GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/serviceradar-agent"
    cd "${BASE_DIR}"  # Return to base directory
    echo "Binary built successfully"
else
    echo "Warning: Go source directory not found at ${GO_SRC_DIR}. Skipping binary build."
fi

echo "Creating package files..."

# Create control file (or copy and modify existing one)
if [ -f "${PACKAGING_DIR}/agent/DEBIAN/control" ]; then
    echo "Copying control file from ${PACKAGING_DIR}/agent/DEBIAN/control"
    cp "${PACKAGING_DIR}/agent/DEBIAN/control" "${PKG_ROOT}/DEBIAN/control"
    # Update the version in control file
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS uses BSD sed
        sed -i '' "s/^Version:.*/Version: ${VERSION}/" "${PKG_ROOT}/DEBIAN/control"
    else
        # Linux uses GNU sed
        sed -i "s/^Version:.*/Version: ${VERSION}/" "${PKG_ROOT}/DEBIAN/control"
    fi
    echo "Control file updated with version ${VERSION}"
else
    echo "Creating new control file"
    cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-agent
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman@carverauto.dev>
Description: ServiceRadar Agent Service
 ServiceRadar Agent is a lightweight agent that collects network performance data
 and sends it to the ServiceRadar server for analysis and visualization.
Config: /etc/serviceradar/agent.json
EOF
fi

# Create conffiles to mark configuration files
if [ -f "${PACKAGING_DIR}/agent/DEBIAN/conffiles" ]; then
    echo "Copying conffiles from ${PACKAGING_DIR}/agent/DEBIAN/conffiles"
    cp "${PACKAGING_DIR}/agent/DEBIAN/conffiles" "${PKG_ROOT}/DEBIAN/conffiles"
else
    echo "Creating new conffiles"
    cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/agent.json
/etc/serviceradar/checkers/sweep/sweep.json
EOF
fi

# Copy systemd service file
SERVICE_FILE_SRC="${PACKAGING_DIR}/agent/systemd/serviceradar-agent.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    echo "Copying serviceradar-agent.service from ${SERVICE_FILE_SRC}"
    cp "$SERVICE_FILE_SRC" "${PKG_ROOT}/lib/systemd/system/serviceradar-agent.service"
else
    echo "Error: serviceradar-agent.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy agent configuration file
AGENT_CONFIG_SRC="${PACKAGING_DIR}/agent/config/agent.json"
if [ -f "$AGENT_CONFIG_SRC" ]; then
    echo "Copying agent.json from ${AGENT_CONFIG_SRC}"
    cp "$AGENT_CONFIG_SRC" "${PKG_ROOT}/etc/serviceradar/agent.json"
else
    echo "Error: agent.json not found at $AGENT_CONFIG_SRC"
    exit 1
fi

# Copy sweep configuration file
SWEEP_CONFIG_SRC="${PACKAGING_DIR}/agent/config/checkers/sweep/sweep.json"
if [ -f "$SWEEP_CONFIG_SRC" ]; then
    echo "Copying sweep.json from ${SWEEP_CONFIG_SRC}"
    cp "$SWEEP_CONFIG_SRC" "${PKG_ROOT}/etc/serviceradar/checkers/sweep/sweep.json"
elif [ -f "${PACKAGING_DIR}/core/config/checkers/sweep/sweep.json" ]; then
    echo "Copying sweep.json from core directory"
    # Try alternate location
    cp "${PACKAGING_DIR}/core/config/checkers/sweep/sweep.json" "${PKG_ROOT}/etc/serviceradar/checkers/sweep/sweep.json"
else
    echo "Warning: sweep.json not found, creating empty config"
    echo "{}" > "${PKG_ROOT}/etc/serviceradar/checkers/sweep/sweep.json"
fi

# Copy or create postinst script
POSTINST_SRC="${PACKAGING_DIR}/agent/scripts/postinstall.sh"
if [ -f "$POSTINST_SRC" ]; then
    echo "Copying postinst script from ${POSTINST_SRC}"
    cp "$POSTINST_SRC" "${PKG_ROOT}/DEBIAN/postinst"
    chmod 755 "${PKG_ROOT}/DEBIAN/postinst"
else
    echo "Creating new postinst script"
    cat > "${PKG_ROOT}/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Create required directories
mkdir -p /etc/serviceradar
mkdir -p /var/lib/serviceradar
mkdir -p /etc/serviceradar/checkers/sweep

# Set permissions
chown serviceradar:serviceradar /etc/serviceradar/agent.json
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chmod 755 /etc/serviceradar/

# Set required capability for ICMP scanning
if [ -x /usr/local/bin/serviceradar-agent ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent || {
        echo "Warning: Failed to set cap_net_raw capability on /usr/local/bin/serviceradar-agent"
        echo "ICMP scanning will not work without this capability. Ensure libcap2-bin is installed and run:"
        echo "  sudo setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent"
    }
fi

# Reload systemd and start service
systemctl daemon-reload
systemctl enable serviceradar-agent
systemctl start serviceradar-agent || echo "Failed to start service, please check logs with: journalctl -xeu serviceradar-agent"

echo "ServiceRadar Agent installed successfully!"
exit 0
EOF
    chmod 755 "${PKG_ROOT}/DEBIAN/postinst"
fi

# Copy or create prerm script
PRERM_SRC="${PACKAGING_DIR}/agent/scripts/preremove.sh"
if [ -f "$PRERM_SRC" ]; then
    echo "Copying prerm script from ${PRERM_SRC}"
    cp "$PRERM_SRC" "${PKG_ROOT}/DEBIAN/prerm"
    chmod 755 "${PKG_ROOT}/DEBIAN/prerm"
else
    echo "Creating new prerm script"
    cat > "${PKG_ROOT}/DEBIAN/prerm" << 'EOF'
#!/bin/sh
set -e

# Stop and disable service
systemctl stop serviceradar-agent || true
systemctl disable serviceradar-agent || true

exit 0
EOF
    chmod 755 "${PKG_ROOT}/DEBIAN/prerm"
fi

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p "${BASE_DIR}/release-artifacts"

# Build the package
cd "${BASE_DIR}"  # Ensure we're in the base directory for the build
dpkg-deb --root-owner-group --build "${PKG_ROOT##*/}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT##*/}.deb" "${BASE_DIR}/release-artifacts/"

echo "Package built: ${BASE_DIR}/release-artifacts/${PKG_ROOT##*/}.deb"