#!/bin/bash
# setup-deb-poller.sh
set -e  # Exit on any error

echo "Setting up package structure..."

VERSION=${VERSION:-1.0.0}

# Create package directory structure
PKG_ROOT="homemon-poller_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/homemon"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binary..."

# Build poller binary
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/homemon-poller" ./cmd/poller

echo "Creating package files..."

# Create control file
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: homemon-poller
Version: 1.0.0
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Michael Freeman <mfreeman451@gmail.com>
Description: HomeMon poller service
 Poller component for HomeMon monitoring system.
 Collects and forwards monitoring data from agents to cloud service.
Config: /etc/homemon/poller.json
EOF

# Create conffiles to mark configuration files
cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/homemon/poller.json
EOF

# Create systemd service file
cat > "${PKG_ROOT}/lib/systemd/system/homemon-poller.service" << EOF
[Unit]
Description=HomeMon Poller Service
After=network.target

[Service]
Type=simple
User=homemon
ExecStart=/usr/local/bin/homemon-poller -config /etc/homemon/poller.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create default config only if we're creating a fresh package
cat > "${PKG_ROOT}/etc/homemon/poller.json" << EOF
{
    "agents": {
        "local-agent": {
            "address": "127.0.0.1:50051",
            "checks": [
                {
                    "type": "dusk"
                }
            ]
        }
    },
    "cloud_address": "localhost:50052",
    "poll_interval": "30s",
    "poller_id": "home-poller-1"
}
EOF

# Create postinst script
cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# Create homemon user if it doesn't exist
if ! id -u homemon >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin homemon
fi

# Set permissions
chown -R homemon:homemon /etc/homemon
chmod 755 /usr/local/bin/homemon-poller

# Enable and start service
systemctl daemon-reload
systemctl enable homemon-poller
systemctl start homemon-poller

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# Create prerm script
cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable service
systemctl stop homemon-poller
systemctl disable homemon-poller

exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."

# Create release-artifacts directory if it doesn't exist
mkdir -p release-artifacts

# Build the package
dpkg-deb --build "${PKG_ROOT}"

# Move the deb file to the release-artifacts directory
mv "${PKG_ROOT}.deb" "release-artifacts/"

echo "Package built: release-artifacts/${PKG_ROOT}.deb"
