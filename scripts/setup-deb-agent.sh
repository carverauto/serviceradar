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

VERSION=${VERSION:-1.0.24}
echo "Building serviceradar-agent version ${VERSION}"

echo "Setting up package structure..."

# Create package directory structure
PKG_ROOT="serviceradar-agent_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar/checkers"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binaries..."

# Build agent and checker binaries
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/serviceradar-agent" ./cmd/agent

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

cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/agent.json
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-agent.service" << EOF
[Unit]
Description=ServiceRadar Agent Service
After=network.target

[Service]
Type=simple
User=serviceradar
ExecStart=/usr/local/bin/serviceradar-agent
Restart=always
RestartSec=10
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF


cat > "${PKG_ROOT}/etc/serviceradar/agent.json" << EOF
{
    "checkers_dir": "/etc/serviceradar/checkers",
    "listen_addr": ":50051",
    "service_type": "grpc",
    "service_name": "AgentService",
    "security": {
        "mode": "none",
        "cert_dir": "/etc/serviceradar/certs",
        "server_name": "changeme",
        "role": "agent"
    }
}
EOF

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
systemctl stop serviceradar-agent
systemctl disable serviceradar-agent

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p ./release-artifacts

# Build the package
dpkg-deb --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "./release-artifacts/"

echo "Package built: release-artifacts/${PKG_ROOT}.deb"
