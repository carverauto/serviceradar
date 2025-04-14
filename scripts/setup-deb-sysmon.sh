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

set -e

# Get script directory and navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${SCRIPT_DIR}/.."

# Set version (default to git describe if not provided)
VERSION=${VERSION:-$(git describe --tags --always)}
# Clean version for package (replace '-' with '~')
VERSION_CLEAN=$(echo "${VERSION}" | sed 's/-/~/g')

# Package metadata
PKG_NAME="serviceradar-sysmon-checker"
MAINTAINER="Carver Automation Corporation <support@carverauto.dev>"
DESCRIPTION="ServiceRadar SysMon System Metrics Checker"

# Temp directory for package creation
TEMP_DIR=$(mktemp -d)
trap 'rm -rf ${TEMP_DIR}' EXIT

# Create package directory structure
mkdir -p "${TEMP_DIR}/DEBIAN"
mkdir -p "${TEMP_DIR}/usr/local/bin"
mkdir -p "${TEMP_DIR}/etc/serviceradar/checkers"
mkdir -p "${TEMP_DIR}/lib/systemd/system"
mkdir -p "${TEMP_DIR}/var/log/serviceradar"

# Generate protobuf code (if sysmon uses gRPC)
echo "Generating protobuf code for sysmon..."
protoc -I=proto \
    --go_out=proto --go_opt=paths=source_relative \
    --go-grpc_out=proto --go-grpc_opt=paths=source_relative \
    proto/sysmon/sysmon.proto || true # Skip if no proto file

# Build the checker using Docker
echo "Building Rust sysmon checker in Docker for AMD64..."
docker build \
    --platform linux/amd64 \
    -t serviceradar-sysmon-checker-builder \
    -f cmd/checkers/sysmon/Dockerfile \
    --target builder \
    .

# Extract the binary from the container
docker create --name temp-sysmon-builder serviceradar-sysmon-checker-builder
docker cp temp-sysmon-builder:/usr/src/serviceradar/target/release/serviceradar-sysmon-checker "${TEMP_DIR}/usr/local/bin/serviceradar-sysmon-checker"
docker rm temp-sysmon-builder

# Verify the binary
echo "Verifying binary architecture..."
file "${TEMP_DIR}/usr/local/bin/serviceradar-sysmon-checker"

# Create systemd service file
cat > "${TEMP_DIR}/lib/systemd/system/serviceradar-sysmon-checker.service" << EOF
[Unit]
Description=ServiceRadar SysMon Checker
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/serviceradar-sysmon-checker --config /etc/serviceradar/checkers/sysmon.json
Restart=on-failure
User=serviceradar
Group=serviceradar
StandardOutput=append:/var/log/serviceradar/sysmon.log
StandardError=append:/var/log/serviceradar/sysmon.log

[Install]
WantedBy=multi-user.target
EOF

# Create sample config file
cat > "${TEMP_DIR}/etc/serviceradar/checkers/sysmon.json.example" << EOF
{
  "listen_addr": "0.0.0.0:50060",
  "security": {
    "tls_enabled": false,
    "cert_file": null,
    "key_file": null
  },
  "poll_interval": 30,
  "metrics": {
    "cpu": {
      "enabled": true,
      "cores": []
    },
    "disk": {
      "enabled": true,
      "mount_points": ["/", "/var"]
    },
    "memory": {
      "enabled": true
    },
    "zfs": {
      "enabled": true,
      "pools": []
    }
  }
}
EOF

# Create DEBIAN/control file
cat > "${TEMP_DIR}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${VERSION_CLEAN}
Architecture: amd64
Maintainer: ${MAINTAINER}
Section: admin
Priority: optional
Depends: libzfs4, systemd
Homepage: https://github.com/carverauto/serviceradar
Description: ${DESCRIPTION}
 A system metrics checker for ServiceRadar, collecting CPU, disk, memory, and ZFS metrics.
 This plugin monitors system performance and reports to the ServiceRadar core service.
EOF

# Create DEBIAN/postinst file
cat > "${TEMP_DIR}/DEBIAN/postinst" << EOF
#!/bin/sh
set -e

# Create serviceradar user and group if they don't exist
if ! getent group serviceradar >/dev/null; then
    addgroup --quiet --system serviceradar
fi
if ! getent passwd serviceradar >/dev/null; then
    adduser --quiet --system --ingroup serviceradar --no-create-home --disabled-password --shell /usr/sbin/nologin serviceradar
fi

# Create log directory
mkdir -p /var/log/serviceradar
chown serviceradar:serviceradar /var/log/serviceradar
chmod 750 /var/log/serviceradar

# Copy example config if real config doesn't exist
if [ ! -f /etc/serviceradar/checkers/sysmon.json ]; then
    cp /etc/serviceradar/checkers/sysmon.json.example /etc/serviceradar/checkers/sysmon.json
    chown serviceradar:serviceradar /etc/serviceradar/checkers/sysmon.json
    chmod 640 /etc/serviceradar/checkers/sysmon.json
fi

# Enable and start systemd service
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable serviceradar-sysmon-checker.service >/dev/null 2>&1 || true
    systemctl restart serviceradar-sysmon-checker.service >/dev/null 2>&1 || true
fi

exit 0
EOF

# Create DEBIAN/prerm file
cat > "${TEMP_DIR}/DEBIAN/prerm" << EOF
#!/bin/sh
set -e

# Stop and disable systemd service
if [ -d /run/systemd/system ]; then
    systemctl --no-reload disable serviceradar-sysmon-checker.service >/dev/null 2>&1 || true
    systemctl stop serviceradar-sysmon-checker.service >/dev/null 2>&1 || true
fi

exit 0
EOF

# Make scripts executable
chmod 755 "${TEMP_DIR}/DEBIAN/postinst"
chmod 755 "${TEMP_DIR}/DEBIAN/prerm"

# Set permissions for binary
chmod 755 "${TEMP_DIR}/usr/local/bin/serviceradar-sysmon-checker"

# Build the package
mkdir -p release-artifacts/
DEB_FILE="release-artifacts/${PKG_NAME}_${VERSION_CLEAN}.deb"
dpkg-deb --root-owner-group --build "${TEMP_DIR}" "${DEB_FILE}"

echo "Package built: ${DEB_FILE}"