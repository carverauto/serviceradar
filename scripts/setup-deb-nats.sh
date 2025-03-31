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

VERSION=${VERSION:-1.0.27}
NATS_VERSION=${NATS_VERSION:-2.11.0}  # Default NATS Server version

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
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar NATS JetStream service
 Provides NATS JetStream server configured for ServiceRadar KV store functionality.
Config: /etc/nats/nats-server.conf
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/nats/nats-server.conf
EOF

# Create NATS configuration file
cat > "${PKG_ROOT}/etc/nats/nats-server.conf" << EOF
# NATS Server Configuration for ServiceRadar KV Store

# Listen on the default NATS port (restricted to localhost for security)
port: 4222
listen: 127.0.0.1

# Server identification
server_name: nats-serviceradar

# Enable JetStream for KV store
jetstream {
  # Directory to store JetStream data
  store_dir: /var/lib/nats/jetstream
  # Maximum storage size
  max_memory_store: 1G
  # Maximum disk storage
  max_file_store: 10G
}

# Enable mTLS for secure communication
tls {
  # Path to the server certificate
  cert_file: "/etc/serviceradar/certs/nats-server.pem"
  # Path to the server private key
  key_file: "/etc/serviceradar/certs/nats-server-key.pem"
  # Path to the root CA certificate for verifying clients
  ca_file: "/etc/serviceradar/certs/root.pem"

  # Require client certificates (enables mTLS)
  verify: true
  # Require and verify client certificates
  verify_and_map: true
}

# Logging settings
logfile: "/var/log/nats/nats.log"
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-nats.service" << EOF
[Unit]
Description=NATS Server for ServiceRadar
After=network-online.target ntp.service

[Service]
Type=simple
ExecStart=/usr/bin/nats-server -c /etc/nats/nats-server.conf
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s SIGINT \$MAINPID
User=nats
Group=nats
Restart=always
RestartSec=5
KillSignal=SIGUSR2
LimitNOFILE=800000

# Security hardening
CapabilityBoundingSet=
LockPersonality=true
MemoryDenyWriteExecute=true
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
PrivateUsers=true
ProcSubset=pid
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallFilter=@system-service ~@privileged ~@resources
UMask=0077
ReadWritePaths=/var/lib/nats /var/log/nats

[Install]
WantedBy=multi-user.target
Alias=nats.service
EOF

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

# Add nats user to serviceradar group
sudo usermod -aG serviceradar nats
# Allow nats user to read the ServiceRadar certificates
sudo chmod 750 /etc/serviceradar/certs/

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