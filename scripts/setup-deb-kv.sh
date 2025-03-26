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

echo "Setting up package structure..."

VERSION=${VERSION:-1.0.27}
BUILD_TAGS=${BUILD_TAGS:-""}

# Create package directory structure
PKG_ROOT="serviceradar-kv_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar"
mkdir -p "${PKG_ROOT}/etc/nginx/conf.d"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binary..."

# Build Go binary with or without container tags
BUILD_CMD="CGO_ENABLED=1 GOOS=linux GOARCH=amd64"
if [[ ! -z "$BUILD_TAGS" ]]; then
    BUILD_CMD="$BUILD_CMD GOFLAGS=\"-tags=$BUILD_TAGS\""
fi
BUILD_CMD="$BUILD_CMD go build -o \"../../${PKG_ROOT}/usr/local/bin/serviceradar-kv\""

# Build Go binary
cd cmd/kv
eval $BUILD_CMD
cd ../..

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-kv
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd, nginx
Recommends: serviceradar-web
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: ServiceRadar KV service
  Key-Value store component for ServiceRadar monitoring system.
Config: /etc/serviceradar/kv.json
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/kv.json
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-kv.service" << EOF
[Unit]
Description=ServiceRadar Key-Value Store Service
After=network.target

[Service]
Type=simple
User=serviceradar
EnvironmentFile=/etc/serviceradar/api.env
ExecStart=/usr/local/bin/serviceradar-kv -config /etc/serviceradar/kv.json
Restart=always
RestartSec=10
TimeoutStopSec=20
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

# Create default config file
cat > "${PKG_ROOT}/etc/serviceradar/kv.json" << EOF
{
  "listen_addr": ":50054",
  "nats_url": "nats://localhost:4222",
  "security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "nats-serviceradar",
    "role": "server",
    "tls": {
      "cert_file": "kv-serviceradar.pem",
      "key_file": "kv-serviceradar-key.pem",
      "ca_file": "root.pem",
      "client_ca_file": "root.pem"
    }
  },
  "rbac": {
    "roles": [
      {"identity": "CN=sync.serviceradar,O=ServiceRadar", "role": "writer"},
      {"identity": "CN=agent.serviceradar,O=ServiceRadar", "role": "reader"}
    ]
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
chmod 755 /usr/local/bin/serviceradar-kv

# Ensure api.env exists and has API_KEY and JWT_SECRET
if [ ! -f "/etc/serviceradar/api.env" ]; then
    echo "Generating new api.env with API_KEY and JWT_SECRET..."
    API_KEY=\$(openssl rand -hex 32)
    JWT_SECRET=\$(openssl rand -hex 32)
    echo "API_KEY=\$API_KEY" > /etc/serviceradar/api.env
    echo "JWT_SECRET=\$JWT_SECRET" >> /etc/serviceradar/api.env
    echo "AUTH_ENABLED=false" >> /etc/serviceradar/api.env
    chmod 600 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
    echo "New API key and JWT_SECRET generated and stored in /etc/serviceradar/api.env"
else
    # Check if JWT_SECRET is missing and add it
    if ! grep -q "^JWT_SECRET=" /etc/serviceradar/api.env; then
        echo "Adding JWT_SECRET to existing api.env..."
        JWT_SECRET=\$(openssl rand -hex 32)
        echo "JWT_SECRET=\$JWT_SECRET" >> /etc/serviceradar/api.env
        chmod 600 /etc/serviceradar/api.env
        chown serviceradar:serviceradar /etc/serviceradar/api.env
        echo "JWT_SECRET added to /etc/serviceradar/api.env"
    fi
    # Check if AUTH_ENABLED is missing and add it
    if ! grep -q "^AUTH_ENABLED=" /etc/serviceradar/api.env; then
        echo "Adding AUTH_ENABLED to existing api.env..."
        echo "AUTH_ENABLED=false" >> /etc/serviceradar/api.env
        chmod 600 /etc/serviceradar/api.env
        chown serviceradar:serviceradar /etc/serviceradar/api.env
        echo "AUTH_ENABLED added to /etc/serviceradar/api.env"
    fi
fi

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-kv
systemctl start serviceradar-kv || echo "Failed to start service, please check the logs"

echo "ServiceRadar KV service installed successfully!"

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

EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p ./release-artifacts

# Build the package with root-owner-group to avoid ownership warnings
dpkg-deb --root-owner-group --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "./release-artifacts/"

if [[ ! -z "$BUILD_TAGS" ]]; then
    # For tagged builds, add the tag to the filename
    PACKAGE_NAME="serviceradar-kv_${VERSION}-${BUILD_TAGS//,/_}.deb"
    mv "./release-artifacts/${PKG_ROOT}.deb" "./release-artifacts/$PACKAGE_NAME"
    echo "Package built: release-artifacts/$PACKAGE_NAME"
else
    echo "Package built: release-artifacts/${PKG_ROOT}.deb"
fi