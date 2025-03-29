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

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
cd "${SCRIPT_DIR}/.."

# Set version (default to git describe if not provided)
VERSION=${VERSION:-$(git describe --tags --always)}
# Clean version for package
VERSION_CLEAN=$(echo "${VERSION}" | sed 's/-/~/g')

# Package name
PKG_NAME="serviceradar-rperf-checker"
MAINTAINER="Carver Automation Corporation <support@carverauto.com>"
DESCRIPTION="ServiceRadar RPerf Network Performance Test Checker"

# Temp directory for package creation
TEMP_DIR=$(mktemp -d)
trap 'rm -rf ${TEMP_DIR}' EXIT

# Create package directory structure
mkdir -p "${TEMP_DIR}/DEBIAN"
mkdir -p "${TEMP_DIR}/usr/bin"
mkdir -p "${TEMP_DIR}/etc/serviceradar/checkers"
mkdir -p "${TEMP_DIR}/lib/systemd/system"

# Generate protobuf code and build the plugin
echo "Building Rust rperf plugin..."
protoc -I=proto \
    --go_out=proto --go_opt=paths=source_relative \
    --go-grpc_out=proto --go-grpc_opt=paths=source_relative \
    proto/rperf/rperf.proto

cd cmd/checkers/rperf
cargo build --release
cd ../..

# Copy binary to package
cp cmd/checkers/rperf/target/release/rperf "${TEMP_DIR}/usr/bin/serviceradar-rperf-checker"

# Create systemd service file
cat > "${TEMP_DIR}/lib/systemd/system/serviceradar-rperf-checker.service" << EOF
[Unit]
Description=ServiceRadar RPerf Network Performance Checker
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/serviceradar-rperf-checker --address 0.0.0.0:50051 --rperf-path /usr/bin/rperf
Restart=on-failure
User=serviceradar
Group=serviceradar

[Install]
WantedBy=multi-user.target
EOF

# Create sample config file
cat > "${TEMP_DIR}/etc/serviceradar/checkers/rperf.json" << EOF
{
  "type": "rperf",
  "config": {
    "server_address": "localhost:50051",
    "target_address": "example.com",
    "port": 5201,
    "protocol": "tcp",
    "timeout": "1m",
    "bandwidth": 100000000,
    "duration": 10.0,
    "parallel": 4,
    "test_interval": "1h",
    "security": {
      "tls_enabled": false
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
Depends: rperf (>= 0.1.8)
Section: net
Priority: optional
Homepage: https://github.com/carverauto/serviceradar
Description: ${DESCRIPTION}
 A gRPC wrapper for the rperf network performance testing tool.
 This plugin allows ServiceRadar to monitor network performance metrics
 such as throughput, latency, jitter, and packet loss.
EOF

# Create DEBIAN/postinst file
cat > "${TEMP_DIR}/DEBIAN/postinst" << EOF
#!/bin/sh
set -e

# Create serviceradar user if it doesn't exist
if ! getent group serviceradar >/dev/null; then
    addgroup --quiet --system serviceradar
fi
if ! getent passwd serviceradar >/dev/null; then
    adduser --quiet --system --ingroup serviceradar --no-create-home --disabled-password --shell /usr/sbin/nologin serviceradar
fi

# Enable and start systemd service
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable serviceradar-rperf-checker.service >/dev/null 2>&1 || true
    systemctl restart serviceradar-rperf-checker.service >/dev/null 2>&1 || true
fi

exit 0
EOF

# Create DEBIAN/prerm file
cat > "${TEMP_DIR}/DEBIAN/prerm" << EOF
#!/bin/sh
set -e

# Stop and disable systemd service
if [ -d /run/systemd/system ]; then
    systemctl --no-reload disable serviceradar-rperf-checker.service >/dev/null 2>&1 || true
    systemctl stop serviceradar-rperf-checker.service >/dev/null 2>&1 || true
fi

exit 0
EOF

# Make scripts executable
chmod 755 "${TEMP_DIR}/DEBIAN/postinst"
chmod 755 "${TEMP_DIR}/DEBIAN/prerm"

# Build the package
mkdir -p release-artifacts/deb
DEB_FILE="release-artifacts/deb/${PKG_NAME}_${VERSION_CLEAN}_amd64.deb"
dpkg-deb --root-owner-group --build "${TEMP_DIR}" "${DEB_FILE}"

echo "Package built: ${DEB_FILE}"
